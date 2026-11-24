# 构建 OpenWrt 25.12+ 使用的 APK v3 (apk-tools) 包
$ErrorActionPreference = "Stop"

$ROOT = $PSScriptRoot
$VERSION = "1.0.58"
$RELEASE = "1"
$APKVER = "$VERSION-r$RELEASE"
$STAGE = "$ROOT\tmp_apk\stage"
$FILES = "$STAGE\files"
$SCRIPTS = "$STAGE\scripts"

function ConvertTo-LFRecursive {
    param([string]$Dir)
    Get-ChildItem -Recurse -File -Path $Dir | ForEach-Object {
        $bytes = [IO.File]::ReadAllBytes($_.FullName)
        if ($bytes -contains 13) {
            $text = [Text.Encoding]::UTF8.GetString($bytes)
            $text = ($text -replace "`r`n", "`n") -replace "`r", ""
            [IO.File]::WriteAllBytes($_.FullName, [Text.Encoding]::UTF8.GetBytes($text))
        }
    }
}

Remove-Item -Recurse -Force $STAGE -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force "$ROOT\tmp_apk" | Out-Null
$minirootfs = "$ROOT\tmp_apk\minirootfs.tar.gz"
if (-not (Test-Path $minirootfs)) {
    Write-Host "下载 Alpine minirootfs（提供 apk-tools 3.x）..." -ForegroundColor Cyan
    Invoke-WebRequest -Uri 'https://dl-cdn.alpinelinux.org/alpine/v3.23/releases/x86_64/alpine-minirootfs-3.23.8-x86_64.tar.gz' -OutFile $minirootfs -TimeoutSec 180
}
New-Item -ItemType Directory -Force $FILES | Out-Null
New-Item -ItemType Directory -Force $SCRIPTS | Out-Null

# 数据文件：核心脚本 + LuCI 界面 + uci-defaults + 版本文件
Get-ChildItem -Path "$ROOT\network-detector\files" | ForEach-Object {
    Copy-Item -Recurse -Force $_.FullName -Destination $FILES
}
$luciLua = "$FILES\usr\lib\lua\luci"
New-Item -ItemType Directory -Force $luciLua | Out-Null
Copy-Item -Recurse -Force "$ROOT\luci-app-network-detector\luasrc\*" $luciLua
New-Item -ItemType Directory -Force "$FILES\etc\uci-defaults" | Out-Null
Copy-Item -Recurse -Force "$ROOT\luci-app-network-detector\root\etc\uci-defaults\*" "$FILES\etc\uci-defaults"
New-Item -ItemType Directory -Force "$FILES\usr\share\network-detector" | Out-Null
[IO.File]::WriteAllText("$FILES\usr\share\network-detector\version", "$VERSION`n", [Text.UTF8Encoding]::new($false))

# OpenWrt APK 官方 conffiles 元数据：缺少它会导致升级时报 1 error 并生成 .apk-new
$pkgDir = "$FILES\lib\apk\packages"
New-Item -ItemType Directory -Force $pkgDir | Out-Null
[IO.File]::WriteAllText("$pkgDir\luci-app-network-detector.conffiles", "/etc/config/network-detector`n", [Text.UTF8Encoding]::new($false))
$cfgHash = (Get-FileHash "$FILES\etc\config\network-detector" -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText("$pkgDir\luci-app-network-detector.conffiles_static", "/etc/config/network-detector $cfgHash`n", [Text.UTF8Encoding]::new($false))

ConvertTo-LFRecursive -Dir $FILES

# apk 脚本：按 OpenWrt 官方模式 source /lib/functions.sh 并调用 default_postinst/default_prerm，
# 让运行期正确处理 conffiles 和 uci-defaults，避免 apk 记 error
$postBody = @'
[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0
[ -s "${IPKG_INSTROOT}/lib/functions.sh" ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
export root="${IPKG_INSTROOT}"
export pkgname="luci-app-network-detector"
add_group_and_user
default_postinst
rm -rf ${IPKG_INSTROOT}/tmp/luci-modulecache/ ${IPKG_INSTROOT}/tmp/luci-indexcache* 2>/dev/null || true
if [ -x ${IPKG_INSTROOT}/etc/init.d/network-detector ]; then
    ${IPKG_INSTROOT}/etc/init.d/network-detector enable >/dev/null 2>&1 || true
    ${IPKG_INSTROOT}/etc/init.d/network-detector start >/dev/null 2>&1 || true
fi
exit 0
'@

$post = "#!/bin/sh`n" + $postBody
$postUpgrade = "#!/bin/sh`nexport PKG_UPGRADE=1`n" + $postBody

$preUpgrade = @'
#!/bin/sh
[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0
export PKG_UPGRADE=1
if [ -x /etc/init.d/network-detector ]; then
    /etc/init.d/network-detector stop >/dev/null 2>&1 || true
fi
exit 0
'@

$preRemove = @'
#!/bin/sh
[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0
[ -s "${IPKG_INSTROOT}/lib/functions.sh" ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
export root="${IPKG_INSTROOT}"
export pkgname="luci-app-network-detector"
default_prerm
if [ -x ${IPKG_INSTROOT}/etc/init.d/network-detector ]; then
    ${IPKG_INSTROOT}/etc/init.d/network-detector stop >/dev/null 2>&1 || true
    ${IPKG_INSTROOT}/etc/init.d/network-detector disable >/dev/null 2>&1 || true
fi
rm -f ${IPKG_INSTROOT}/var/run/network-detector.pid ${IPKG_INSTROOT}/var/run/network-detector.scheduler.pid ${IPKG_INSTROOT}/var/run/network-detector.trigger 2>/dev/null || true
rm -f ${IPKG_INSTROOT}/var/log/network-detector.log ${IPKG_INSTROOT}/var/lib/network-detector/counters 2>/dev/null || true
rm -rf ${IPKG_INSTROOT}/tmp/luci-modulecache/ ${IPKG_INSTROOT}/tmp/luci-indexcache* 2>/dev/null || true
exit 0
'@

foreach ($pair in @(
    @{ Name = 'post-install';  Body = $post },
    @{ Name = 'post-upgrade';  Body = $postUpgrade },
    @{ Name = 'pre-upgrade';   Body = $preUpgrade },
    @{ Name = 'pre-deinstall'; Body = $preRemove }
)) {
    [IO.File]::WriteAllText("$SCRIPTS\$($pair.Name)", ($pair.Body -replace "`r`n", "`n"), [Text.UTF8Encoding]::new($false))
}

Write-Host "[OK] staging: $STAGE" -ForegroundColor Green
$unixRoot = "/mnt/" + $ROOT.Substring(0, 1).ToLower() + $ROOT.Substring(2).Replace('\', '/')
& wsl -e sh "$unixRoot/build-apk.sh"
if ($LASTEXITCODE -ne 0) { throw "APK build failed" }
