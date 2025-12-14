# Copyright 2025 OneNAS.space, Jackie264 (jackie.han@gmail.com).

include $(TOPDIR)/rules.mk

PKG_NAME:=keepalived-scripts
PKG_VERSION:=1.0.1
PKG_RELEASE:=2

PKG_BUILD_DIR := $(BUILD_DIR)/$(PKG_NAME)

include $(INCLUDE_DIR)/package.mk

define Package/keepalived-scripts
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Keepalived user scripts for openwrt
  DEPENDS:=
  PKGARCH:=all
endef

define Package/keepalived-scripts/description
 Scripts of keepalived. Functions with modify services on status changed.
endef

define Package/keepalived-scripts/conffiles
/etc/keepalived.user
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
endef

define Build/Compile
	# nothing to compile, shell scripts only
endef

define Package/keepalived-scripts/install
	$(INSTALL_DIR) $(1)/etc
	$(INSTALL_CONF) ./files/etc/keepalived.user $(1)/etc/keepalived.user

	$(INSTALL_DIR) $(1)/usr/share/keepalived/scripts
	$(INSTALL_BIN) ./files/usr/share/keepalived/scripts/agh_bind_hosts.sh $(1)/usr/share/keepalived/scripts/agh_bind_hosts.sh
	$(INSTALL_BIN) ./files/usr/share/keepalived/scripts/get_lan_vip.sh $(1)/usr/share/keepalived/scripts/get_lan_vip.sh
	$(INSTALL_BIN) ./files/usr/share/keepalived/scripts/sync_leases.sh $(1)/usr/share/keepalived/scripts/sync_leases.sh

	$(INSTALL_DIR) $(1)/etc/keepalived/scripts
	$(LN) /usr/share/keepalived/scripts/agh_bind_hosts.sh $(1)/etc/keepalived/scripts/agh_bind_hosts.sh
	$(LN) /usr/share/keepalived/scripts/get_lan_vip.sh $(1)/etc/keepalived/scripts/get_lan_vip.sh
	$(LN) /usr/share/keepalived/scripts/sync_leases.sh $(1)/etc/keepalived/scripts/sync_leases.sh
endef

$(eval $(call BuildPackage,keepalived-scripts))
