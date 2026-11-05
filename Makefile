# Copyright 2025 OneNAS.space, Jackie264 (jackie.han@gmail.com).

include $(TOPDIR)/rules.mk

PKG_LICENSE:=GPL-3.0-or-later
PKG_MAINTAINER:=Jackie Han <jackie.han@gmail.com>
PKG_NAME:=luci-app-vrrp-actions
PKG_VERSION:=1.0.1
PKG_RELEASE:=1

PKG_BUILD_DIR := $(BUILD_DIR)/$(PKG_NAME)

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-vrrp-actions
	SECTION:=luci
	CATEGORY:=LuCI
	SUBMENU:=3. Applications
	TITLE:=Keepalived user scripts for openwrt, with a LuCI page
	DEPENDS:=+luci-base +luci-app-keepalived +keepalived +rsync +inotifywait
	CONFLICTS:=keepalived-scripts
	PKGARCH:=all
endef

define Package/luci-app-vrrp-actions/description
 Scripts of keepalived. Functions with modify services on status changed.
 A Role Actions tab in the VRRP menu edits their settings.
endef

define Package/luci-app-vrrp-actions/conffiles
/etc/config/keepalived_scripts
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
endef

define Build/Compile
endef

define Package/luci-app-vrrp-actions/install
	$(INSTALL_DIR) $(1)/etc/hotplug.d/keepalived
	$(INSTALL_DATA) ./files/etc/hotplug.d/keepalived/560-keepalived-scripts $(1)/etc/hotplug.d/keepalived/560-keepalived-scripts

	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/etc/uci-defaults/99-keepalived-scripts $(1)/etc/uci-defaults/99-keepalived-scripts

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/keepalived_scripts $(1)/etc/config/keepalived_scripts

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/lease_sync $(1)/etc/init.d/lease_sync

	$(INSTALL_DIR) $(1)/usr/share/keepalived/scripts
	$(INSTALL_BIN) ./files/usr/share/keepalived/scripts/sync_dhcp.sh $(1)/usr/share/keepalived/scripts/sync_dhcp.sh

	$(INSTALL_DIR) $(1)/etc/keepalived/scripts
	$(LN) /usr/share/keepalived/scripts/sync_dhcp.sh $(1)/etc/keepalived/scripts/sync_dhcp.sh

	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./files/usr/share/rpcd/acl.d/luci-app-vrrp-actions.json $(1)/usr/share/rpcd/acl.d/luci-app-vrrp-actions.json

	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./files/usr/share/luci/menu.d/luci-app-vrrp-actions.json $(1)/usr/share/luci/menu.d/luci-app-vrrp-actions.json

	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/keepalived_scripts
	$(INSTALL_DATA) ./files/www/luci-static/resources/view/keepalived_scripts/actions.js $(1)/www/luci-static/resources/view/keepalived_scripts/actions.js
endef

define Package/luci-app-vrrp-actions/postinst
#!/bin/sh
if [ -z "$${IPKG_INSTROOT}" ]; then
	/etc/init.d/lease_sync enable
	rm -f /tmp/luci-indexcache.*
	rm -rf /tmp/luci-modulecache/
	# the new ACL file is only read after rpcd is told to (web sessions are reset once)
	killall -HUP rpcd 2>/dev/null
fi
exit 0
endef

define Package/luci-app-vrrp-actions/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || /etc/init.d/lease_sync disable
exit 0
endef

$(eval $(call BuildPackage,luci-app-vrrp-actions))
