#    Copyright © 2017 gigibox zhangzengfei@kunteng.org
#
#    This program is free software; you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation; either version 2 of the License, or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    The full GNU General Public License is included in this distribution
#    in the file called "COPYING".

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-xkcptun
PKG_VERSION:=1.0
PKG_RELEASE:=3
PKG_LICENSE:=GPL-3.0-or-later

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-xkcptun
	SECTION:=luci
	CATEGORY:=LuCI
	SUBMENU:=3. Applications
	TITLE:=LuCI support for xkcptun
	URL:=https://github.com/liudf0716/xkcptun
	MAINTAINER:=Lars Gierth <larsg@systemli.org>
	PKGARCH:=all
	# luci-compat provides the legacy Lua dispatcher that this app is built on;
	# luci-lib-ipkg provides the luci.model.ipkg module the CBI model requires.
	DEPENDS:=+luci-base+luci-compat+luci-lib-ipkg
endef

define Package/luci-app-xkcptun/description
	This package allows you to configure xkcptun using LuCI.
endef

define Build/Compile
endef

define Package/luci-app-xkcptun/postinst
#!/bin/sh
UCI_DEF_FILE=90_luci_xkcptun
if [ -z "$${IPKG_INSTROOT}" ]; then
	if [ -f /etc/uci-defaults/$UCI_DEF_FILE ]; then
		( . /etc/uci-defaults/$UCI_DEF_FILE ) && \
		rm -f /etc/uci-defaults/$UCI_DEF_FILE
	fi
	rm -rf /tmp/luci-indexcache /tmp/luci-modulecache
fi
exit 0
endef

define Package/luci-app-xkcptun/install
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci
	$(CP) ./luasrc/* $(1)/usr/lib/lua/luci
	$(CP) ./root/* $(1)/
endef

$(eval $(call BuildPackage,luci-app-xkcptun))
