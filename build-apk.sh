#!/bin/sh
# 在 Alpine chroot 中用 apk-tools 3.x 构建 APK v3 包，供 WSL 调用
set -e

ROOT=/mnt/e/GitHub/Clash-Link-main
WORK=/tmp/alpine-root/apkwork
OUT="$ROOT/output/luci-app-network-detector_1.0.58-r1_all.apk"

if [ ! -x /tmp/alpine-root/sbin/apk ]; then
    rm -rf /tmp/alpine-root
    mkdir -p /tmp/alpine-root
    tar -xzf "$ROOT/tmp_apk/minirootfs.tar.gz" -C /tmp/alpine-root
fi

rm -rf "$WORK"
mkdir -p "$WORK"
cp -a "$ROOT/tmp_apk/stage/files" "$WORK/files"
cp -a "$ROOT/tmp_apk/stage/scripts" "$WORK/scripts"

chmod 755 "$WORK/files/usr/bin/network-detector" \
          "$WORK/files/etc/init.d/network-detector" \
          "$WORK/files/etc/uci-defaults/99-luci-network-detector" \
          "$WORK/scripts/"*

export SOURCE_DATE_EPOCH=0
chroot /tmp/alpine-root /sbin/apk mkpkg \
    --info 'name:luci-app-network-detector' \
    --info 'version:1.0.58-r1' \
    --info 'description:Network Detector with LuCI UI - Clash proxy health check, auto node switching' \
    --info 'arch:noarch' \
    --info 'license:GPL-2.0' \
    --info 'origin:network-detector' \
    --info 'url:https://github.com/NTPlay4/Clash-Link' \
    --info 'maintainer:OpenWrt User' \
    --info 'depends:curl jsonfilter luci-base' \
    --script "post-install:/apkwork/scripts/post-install" \
    --script "post-upgrade:/apkwork/scripts/post-upgrade" \
    --script "pre-upgrade:/apkwork/scripts/pre-upgrade" \
    --script "pre-deinstall:/apkwork/scripts/pre-deinstall" \
    --files /apkwork/files \
    --output /apkwork/out.apk

cp "$WORK/out.apk" "$OUT"
echo "[OK] $OUT"
echo "--- apk info ---"
chroot /tmp/alpine-root /sbin/apk info --allow-untrusted --no-network /apkwork/out.apk 2>&1 || true
echo "--- apk metadata ---"
chroot /tmp/alpine-root /sbin/apk adbdump /apkwork/out.apk 2>/dev/null | grep -A5 -E 'depends:|scripts:' || true
