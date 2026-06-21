# Build script: 合并 network-detector + luci-app 为一个 .ipk
# 纯脚本包，无需 OpenWrt SDK 即可打包

$ErrorActionPreference = "Stop"

$OUTDIR = "$PSScriptRoot\output"
$TMPDIR = "$PSScriptRoot\tmp_build"
$VERSION = "1.0.35"
$RELEASE = "1"

# 仅清理临时构建目录，保留 output 中的旧版本
Remove-Item -Recurse -Force $TMPDIR -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $OUTDIR | Out-Null
New-Item -ItemType Directory -Force $TMPDIR | Out-Null

# ============================================================
# 辅助: 写入 Unix(LF) 文件
# ============================================================
function Write-UnixFile {
    param([string]$Path, [string]$Content)
    $text = ($Content -replace "`r`n", "`n") -replace "`r", ""
    if ($text -and !$text.EndsWith("`n")) { $text += "`n" }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
    [System.IO.File]::WriteAllBytes($Path, $bytes)
}

# ============================================================
# 辅助: 将单个文件转为 LF 换行（原地转换）
# ============================================================
function ConvertTo-UnixLF {
    param([string]$Path)
    if ((Test-Path $Path) -and !(Get-Item $Path).PSIsContainer) {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        # 仅处理文本文件（含 \r\n 的）
        if ($bytes -contains 0x0D) {
            $text = [System.Text.Encoding]::UTF8.GetString($bytes)
            $unixText = ($text -replace "`r`n", "`n") -replace "`r", ""
            $unixBytes = [System.Text.Encoding]::UTF8.GetBytes($unixText)
            [System.IO.File]::WriteAllBytes($Path, $unixBytes)
        }
    }
}

# ============================================================
# 辅助: 递归转换目录下所有文件的换行为 LF
# ============================================================
function ConvertTo-UnixLFRecursive {
    param([string]$Dir)
    Get-ChildItem -Recurse -Path $Dir -File | ForEach-Object {
        ConvertTo-UnixLF -Path $_.FullName
    }
}

# ============================================================
# 创建 tar.gz，用 USTAR 格式设置 Unix 权限 755 (rwxr-xr-x)
# Windows tar.exe 不支持 --mode，手动构造 tar header
# ============================================================
function New-TarGz {
    param(
        [string]$OutputPath,
        [string]$SourceDir,
        [int]$Mode = 755
    )

    $outAbs = [System.IO.Path]::GetFullPath($OutputPath)
    $srcAbs = [System.IO.Path]::GetFullPath($SourceDir)

    # 辅助：写 USTAR header  (512 bytes)
    # 参考 https://en.wikipedia.org/wiki/Tar_(computing)#UStar_format
    function Write-TarHeader([System.IO.Stream]$stream, [string]$name, [long]$size, [bool]$isDir) {
        $hdr = [byte[]]::new(512)

        # name (100 bytes)
        $n = [System.Text.Encoding]::ASCII.GetBytes($name)
        [Array]::Copy($n, 0, $hdr, 0, [Math]::Min($n.Length, 100))

        # mode (8 bytes, octal)  e.g. "0000755\0"
        $modeStr = ([Convert]::ToString($Mode, 8)).PadLeft(7, '0'[0]) + "`0"
        $m = [System.Text.Encoding]::ASCII.GetBytes($modeStr)
        [Array]::Copy($m, 0, $hdr, 100, $m.Length)

        # uid/gid = 0
        $hdr[108] = 0x30; $hdr[116] = 0x30  # "0"

        # size (12 bytes, octal)
        $sizeStr = ([Convert]::ToString($size, 8)).PadLeft(11, '0'[0]) + "`0"
        $s = [System.Text.Encoding]::ASCII.GetBytes($sizeStr)
        [Array]::Copy($s, 0, $hdr, 124, $s.Length)

        # mtime = 0
        $hdr[136] = 0x30

        # type flag
        $hdr[156] = if ($isDir) { 0x35 } else { 0x30 }  # '5'=dir, '0'=file

        # magic "ustar" + version "00"
        $magic = [System.Text.Encoding]::ASCII.GetBytes("ustar`0")
        [Array]::Copy($magic, 0, $hdr, 257, 6)
        $hdr[263] = 0x30; $hdr[264] = 0x30

        # uname/gname = "root"
        $root = [System.Text.Encoding]::ASCII.GetBytes("root")
        [Array]::Copy($root, 0, $hdr, 265, 4)
        [Array]::Copy($root, 0, $hdr, 297, 4)

        # checksum: 先填空格, 算 unsigned sum, 再填回去
        for ($i = 148; $i -lt 156; $i++) { $hdr[$i] = 0x20 }
        $sum = 0L; foreach ($b in $hdr) { $sum += $b }
        $csum = ([Convert]::ToString($sum, 8)).PadLeft(6, '0'[0]) + "`0 "
        $cb = [System.Text.Encoding]::ASCII.GetBytes($csum)
        [Array]::Copy($cb, 0, $hdr, 148, $cb.Length)

        $stream.Write($hdr, 0, 512)
    }

    # 收集所有条目 (目录 + 文件, 按路径排序确保父目录先写入)
    $entries = [System.Collections.Generic.List[hashtable]]::new()
    $prefix = $srcAbs.TrimEnd('/', '\')

    $allItems = Get-ChildItem -Recurse -Path $srcAbs | Sort-Object FullName
    # 先加目录
    $dirSeen = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($item in $allItems) {
        if ($item.PSIsContainer) { continue }
        # 确保父目录都加入
        $relDir = (Split-Path $item.FullName).Substring($prefix.Length).TrimStart('/', '\').Replace('\', '/')
        if ($relDir -and $relDir -ne '.') {
            $parts = $relDir.Split('/')
            $cum = ""
            foreach ($p in $parts) {
                $cum += if ($cum) { "/$p" } else { $p }
                if ($dirSeen.Add($cum)) {
                    $entries.Add(@{ Name = $cum; IsDir = $true; Size = 0; Path = "" })
                }
            }
        }
        $relFile = $item.FullName.Substring($prefix.Length).TrimStart('/', '\').Replace('\', '/')
        $entries.Add(@{ Name = $relFile; IsDir = $false; Size = $item.Length; Path = $item.FullName })
    }

    # 写入 tar.gz
    $fs = [System.IO.File]::Create($outAbs)
    try {
        $gzip = [System.IO.Compression.GZipStream]::new($fs, [System.IO.Compression.CompressionMode]::Compress, $true)
        try {
            foreach ($e in $entries) {
                Write-TarHeader $gzip $e.Name $e.Size $e.IsDir
                if (-not $e.IsDir -and $e.Size -gt 0) {
                    $data = [System.IO.File]::ReadAllBytes($e.Path)
                    $gzip.Write($data, 0, $data.Length)
                    # 512 字节对齐
                    $pad = (512 - ($e.Size % 512)) % 512
                    if ($pad) { $gzip.Write([byte[]]::new($pad), 0, $pad) }
                }
            }
            # 结尾双 512-byte 零块
            $gzip.Write([byte[]]::new(1024), 0, 1024)
        } finally { $gzip.Dispose() }
    } finally { $fs.Dispose() }
}

function Build-IPK {
    param(
        [string]$PackageName,  [string]$Version, [string]$Architecture,
        [string]$Section,      [string]$Depends,  [string]$Description,
        [string]$SourceDir,    [string]$PostinstScript, [string]$PrermScript,
        [string[]]$Conffiles
    )
    $pkgdir  = "$TMPDIR\$PackageName"
    $ctldir  = "$pkgdir\CONTROL"
    $datadir = "$pkgdir\data"
    New-Item -ItemType Directory -Force $ctldir  | Out-Null
    New-Item -ItemType Directory -Force $datadir | Out-Null

    $control = @"
Package: $PackageName
Version: ${Version}-${RELEASE}
Architecture: $Architecture
Section: $Section
Priority: optional
Maintainer: OpenWrt User
Depends: $Depends
Description: $Description
"@
    Write-UnixFile -Path "$ctldir\control" -Content $control

    if ($Conffiles -and $Conffiles.Count -gt 0) {
        Write-UnixFile -Path "$ctldir\conffiles" -Content ($Conffiles -join "`n")
    }

    if ($PostinstScript) { Copy-Item $PostinstScript "$ctldir\postinst" }
    if ($PrermScript)    { Copy-Item $PrermScript    "$ctldir\prerm" }

    Get-ChildItem -Path $SourceDir | ForEach-Object {
        Copy-Item -Recurse -Force $_.FullName -Destination $datadir
    }

    $ipkfile = "$OUTDIR\${PackageName}_${Version}-${Release}_${Architecture}.ipk"
    Write-UnixFile -Path "$pkgdir\debian-binary" -Content "2.0"

    $prev = Get-Location

    # 创建 control.tar.gz (postinst/prerm 需要 +x 权限)
    New-TarGz -OutputPath "$pkgdir\control.tar.gz" -SourceDir $ctldir -Mode 755

    # 创建 data.tar.gz
    New-TarGz -OutputPath "$pkgdir\data.tar.gz" -SourceDir $datadir -Mode 755

    Set-Location $pkgdir
    tar -czf $ipkfile debian-binary control.tar.gz data.tar.gz
    Set-Location $prev

    Write-Host "[OK] $ipkfile" -ForegroundColor Green

    Remove-Item -Recurse -Force $ctldir  -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $datadir -ErrorAction SilentlyContinue
    Remove-Item -Force "$pkgdir\debian-binary","$pkgdir\control.tar.gz","$pkgdir\data.tar.gz" -ErrorAction SilentlyContinue
}

# ============================================================
# 合并数据目录: 核心脚本 + LuCI 界面 → 一个 data 树
# ============================================================
$merged = "$TMPDIR\merged-data"
New-Item -ItemType Directory -Force $merged | Out-Null

# 1) 核心脚本 (network-detector/files/ → /)
Get-ChildItem -Path "$PSScriptRoot\network-detector\files" | ForEach-Object {
    Copy-Item -Recurse -Force $_.FullName -Destination $merged
}
# 转换为 Unix 换行
ConvertTo-UnixLFRecursive -Dir $merged

# 2) LuCI controller + model + view (luasrc/ → /usr/lib/lua/luci/)
$luci_lua = "$merged\usr\lib\lua\luci"
New-Item -ItemType Directory -Force $luci_lua | Out-Null
Copy-Item -Recurse "$PSScriptRoot\luci-app-network-detector\luasrc\*" $luci_lua
ConvertTo-UnixLFRecursive -Dir $luci_lua

# 3) uci-defaults (root/etc/uci-defaults/ → /etc/uci-defaults/)
New-Item -ItemType Directory -Force "$merged\etc\uci-defaults" | Out-Null
Copy-Item -Recurse -Force "$PSScriptRoot\luci-app-network-detector\root\etc\uci-defaults\*" "$merged\etc\uci-defaults"
ConvertTo-UnixLFRecursive -Dir "$merged\etc\uci-defaults"

# 4) 版本号文件（供 LuCI 页面读取）
New-Item -ItemType Directory -Force "$merged\usr\share\network-detector" | Out-Null
Write-UnixFile -Path "$merged\usr\share\network-detector\version" -Content $VERSION

# ============================================================
# postinst - 安装后启用服务
# ============================================================
$postinst_path = "$TMPDIR\postinst.sh"
Write-UnixFile -Path $postinst_path -Content @'
#!/bin/sh
# 安装/升级后启用并启动（或重启）服务
[ -n "${IPKG_INSTROOT}" ] && exit 0

# 清除 LuCI 模块缓存，确保前端页面加载最新版本
rm -rf /tmp/luci-modulecache/ /tmp/luci-indexcache* 2>/dev/null

if [ "${1}" = "upgrade" ]; then
    /etc/init.d/network-detector restart 2>/dev/null
else
    /etc/init.d/network-detector enable 2>/dev/null
    /etc/init.d/network-detector start 2>/dev/null
fi
exit 0
'@

# ============================================================
# prerm - 卸载前清理
# ============================================================
$prerm_path = "$TMPDIR\prerm.sh"
Write-UnixFile -Path $prerm_path -Content @'
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] && exit 0

# 正常停止服务
/etc/init.d/network-detector stop 2>/dev/null
/etc/init.d/network-detector disable 2>/dev/null

if [ "${1}" = "upgrade" ]; then
    rm -f /usr/bin/network-detector
    rm -f /etc/init.d/network-detector
    rm -f /etc/uci-defaults/99-luci-network-detector
    rm -f /usr/lib/lua/luci/controller/admin/network_detector.lua
    rm -f /usr/lib/lua/luci/model/cbi/network_detector.lua
    rm -rf /usr/lib/lua/luci/view/network_detector/
    rm -rf /usr/share/network-detector/
    rm -rf /tmp/luci-modulecache/ /tmp/luci-indexcache* 2>/dev/null
else
    rm -f /etc/config/network-detector
    rm -f /usr/bin/network-detector
    rm -f /etc/init.d/network-detector
    rm -f /etc/uci-defaults/99-luci-network-detector
    rm -f /usr/lib/lua/luci/controller/admin/network_detector.lua
    rm -f /usr/lib/lua/luci/model/cbi/network_detector.lua
    rm -rf /usr/lib/lua/luci/view/network_detector/
    rm -rf /usr/share/network-detector/
    rm -f /var/log/network-detector.log
    rm -rf /tmp/luci-modulecache/ /tmp/luci-indexcache* 2>/dev/null
fi
exit 0
'@

# ============================================================
# 打包单文件
# ============================================================
Write-Host "`n=== 打包合并包 ===" -ForegroundColor Cyan

Build-IPK `
    -PackageName "luci-app-network-detector" `
    -Version $VERSION `
    -Architecture "all" `
    -Section "luci" `
    -Depends "libubox, curl, jsonfilter, luci-base" `
    -Description "Network Detector with LuCI UI - Clash proxy health check, auto node switching, webhook notification" `
    -SourceDir $merged `
    -PostinstScript $postinst_path `
    -PrermScript $prerm_path `
    -Conffiles @("/etc/config/network-detector")

# ============================================================
# 验证
# ============================================================
Write-Host "`n=== 输出文件 ===" -ForegroundColor Cyan
Get-ChildItem $OUTDIR\*.ipk | ForEach-Object {
    $size = [math]::Round($_.Length / 1024, 1)
    Write-Host "  $($_.Name)  (${size}KB)" -ForegroundColor White
    Write-Host "    内部文件:" -ForegroundColor DarkGray
    tar -tzf $_.FullName 2>$null | ForEach-Object {
        Write-Host "      $_" -ForegroundColor DarkGray
    }
}

# 列出 data.tar.gz 中的安装路径
Write-Host "`n  安装路径:" -ForegroundColor DarkGray
$tmpv = "$TMPDIR\tmp_verify"
New-Item -ItemType Directory -Force $tmpv | Out-Null
$ipk = Get-ChildItem $OUTDIR\*.ipk | Select-Object -First 1
Set-Location $tmpv
tar -xzf $ipk.FullName data.tar.gz 2>$null
tar -tzf data.tar.gz 2>$null | ForEach-Object {
    if ($_ -ne "./" -and $_ -ne "") { Write-Host "      /$_" -ForegroundColor DarkGray }
}
Set-Location $PSScriptRoot
Remove-Item -Recurse -Force $tmpv -ErrorAction SilentlyContinue

Write-Host "`n打包完成!" -ForegroundColor Green
Write-Host "安装: opkg install /tmp/luci-app-network-detector_*.ipk" -ForegroundColor Yellow
Write-Host "卸载: opkg remove luci-app-network-detector" -ForegroundColor Yellow

Remove-Item -Recurse -Force $TMPDIR -ErrorAction SilentlyContinue
