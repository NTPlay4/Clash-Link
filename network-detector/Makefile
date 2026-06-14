#
# Copyright (C) 2024 OpenWrt.org
#
# This is free software, licensed under the GNU General Public License v2.
# See /LICENSE for more information.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=network-detector
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_LICENSE:=GPL-2.0
PKG_MAINTAINER:=Your Name <you@example.com>

include $(INCLUDE_DIR)/package.mk

define Package/network-detector
    SECTION:=net
    CATEGORY:=Network
    TITLE:=Network detection tool via Clash proxy
    DEPENDS:=+libubox +curl +jsonfilter
    URL:=https://github.com/yourname/network-detector
endef

define Package/network-detector/description
    A network reachability detection tool that works with Clash proxy.
    It periodically checks if target URLs are accessible through the current
    proxy node, automatically switches to the next node on failure,
    and supports Bark push notifications.
    Supports multiple detection tasks configured via UCI.
endef

define Build/Compile
    # 纯脚本包，无需编译
    true
endef

define Package/network-detector/install
    # 安装目录
    $(INSTALL_DIR) $(1)/usr/bin
    $(INSTALL_DIR) $(1)/etc/config
    $(INSTALL_DIR) $(1)/etc/init.d

    # 安装检测脚本 (可执行)
    $(INSTALL_BIN) ./files/usr/bin/network-detector $(1)/usr/bin/

    # 安装 UCI 默认配置
    $(INSTALL_DATA) ./files/etc/config/network-detector $(1)/etc/config/

    # 安装 init 脚本
    $(INSTALL_BIN) ./files/etc/init.d/network-detector $(1)/etc/init.d/
endef

define Package/network-detector/postinst
#!/bin/sh
# 首次安装后启用并启动服务
[ -n "$${IPKG_INSTROOT}" ] && exit 0
/etc/init.d/network-detector enable
/etc/init.d/network-detector start 2>/dev/null
exit 0
endef

define Package/network-detector/prerm
#!/bin/sh
# 卸载前停止服务并清理
[ -n "$${IPKG_INSTROOT}" ] && exit 0
/etc/init.d/network-detector stop 2>/dev/null
/etc/init.d/network-detector disable
if [ -f /etc/crontabs/root ]; then
    sed -i '/network-detector/d' /etc/crontabs/root && /etc/init.d/cron restart 2>/dev/null
fi
rm -f /var/log/network-detector.log
exit 0
endef

$(eval $(call BuildPackage,network-detector))
