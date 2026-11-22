include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-quickstart-network
PKG_VERSION:=0.17.1
PKG_RELEASE:=1

PKG_SOURCE_VERSION:=0183b16726020b4196df064b3cc6173a581c2f9b
PKG_SOURCE:=quickstart-$(PKG_SOURCE_VERSION).tar.gz
PKG_SOURCE_URL:=https://codeload.github.com/istoreos/quickstart/tar.gz
PKG_SOURCE_URL_FILE:=$(PKG_SOURCE_VERSION)
PKG_HASH:=010c1b987e3f5c7b7e8a34e52321e4308d7be686745109ccfb6463ffbf253a8d
PKG_BUILD_DIR:=$(BUILD_DIR)/quickstart-$(PKG_SOURCE_VERSION)

PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE
PKG_BUILD_DEPENDS:=golang/host

include $(INCLUDE_DIR)/package.mk
include $(TOPDIR)/feeds/packages/lang/golang/golang-package.mk

define Package/luci-app-quickstart-network
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=QuickStart network wizard and port configuration
  URL:=https://github.com/istoreos/quickstart
  DEPENDS:=$(GO_ARCH_DEPENDS) +luci-compat +luci-lib-nixio +libuci-lua +ppp-mod-pppoe
endef

define Build/Configure
endef

define Build/Compile
	cd "$(PKG_BUILD_DIR)/backend" && \
		$(GO_PKG_VARS) CGO_ENABLED=0 go build -mod=readonly -buildvcs=false -trimpath \
		-ldflags "-s -w" -o "$(PKG_BUILD_DIR)/quickstart-network" ./cmd/network-only
	cd "$(PKG_BUILD_DIR)/web" && \
		npm ci --no-audit --no-fund && ./node_modules/.bin/vite build
endef

define Package/luci-app-quickstart-network/install
	$(INSTALL_DIR) $(1)/usr/sbin $(1)/etc/init.d
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/quickstart-network $(1)/usr/sbin/
	$(INSTALL_BIN) ./files/quickstart-network.init $(1)/etc/init.d/quickstart-network
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller $(1)/usr/lib/lua/luci/view/quickstart
	$(INSTALL_DATA) ./files/quickstart_network.lua $(1)/usr/lib/lua/luci/controller/
	$(INSTALL_DATA) ./files/network-only.htm $(1)/usr/lib/lua/luci/view/quickstart/
	$(INSTALL_DIR) $(1)/www/luci-static/quickstart-network/i18n
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/web/dist/luci-static/quickstart-network/*.js $(1)/www/luci-static/quickstart-network/
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/web/dist/luci-static/quickstart-network/style.css $(1)/www/luci-static/quickstart-network/
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/web/public/luci-static/quickstart/i18n/en.json $(1)/www/luci-static/quickstart-network/i18n/
endef

$(eval $(call BuildPackage,luci-app-quickstart-network))
