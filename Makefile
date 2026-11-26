#
# h173dash — H173-386 5G CPE yönetim paneli (tek paket)
#
# Vue panel (www/dash) + h173 daemon (ucode, ubus sağlayıcı) + rpcd ACL.
# Saf ucode + statik www: derlenen binary yok → noarch (PKGARCH:=all).
# OpenWrt 24.10+/25.x'te .apk, eski sürümlerde .ipk üretir.
#
include $(TOPDIR)/rules.mk

PKG_NAME:=h173dash
PKG_VERSION:=1.0.0
PKG_RELEASE:=7
PKG_MAINTAINER:=Sekonic
PKG_LICENSE:=MIT

include $(INCLUDE_DIR)/package.mk

define Package/h173dash
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=H173-386 5G CPE yönetim paneli (Vue + ubus)
  URL:=https://github.com/ulas/h173dash
  # Panel + daemon tek pakette. rpcd ubus köprüsü + ucode çalışma-zamanı:
  DEPENDS:=+rpcd +uhttpd +uhttpd-mod-ubus +rpcd-mod-file +rpcd-mod-iwinfo +rpcd-mod-luci \
           +ucode +ucode-mod-digest +ucode-mod-fs +ucode-mod-uloop \
           +ucode-mod-ubus +ucode-mod-uci +ucode-mod-socket
  PKGARCH:=all
endef

define Package/h173dash/description
 Brovi/Zowee H173-386 5G CPE için tek ekran yönetim paneli. h173d daemon'ı modemi
 yoklar ve ubus üzerinden sunar; Vue panel kök URL'de (/dash/) çalışır:
 5G/LTE sinyal + geçmiş grafikleri, bantlar, hücreler, trafik, operatör, SMS;
 mobil veri aç/kapa, yeniden bağlanma, LTE bant seçimi, 5G mod yazma.
 Modem web parolası /etc/config/h173 içindedir (init tarafından chmod 600).
endef

# Derlenecek kaynak yok (ucode + statik www — panel Vite ile önceden derlenmiş)
define Build/Prepare
endef
define Build/Compile
endef

define Package/h173dash/conffiles
/etc/config/h173
endef

define Package/h173dash/install
	# 1) Vue panel (index.html + hash'li assets/: JS, CSS, woff2)
	$(INSTALL_DIR) $(1)/www/dash/assets
	$(INSTALL_DATA) ./files/www/dash/index.html $(1)/www/dash/
	$(INSTALL_DATA) ./files/www/dash/assets/* $(1)/www/dash/assets/
	# kök URL → panele yönlendir
	$(INSTALL_DATA) ./files/www/index.html $(1)/www/index.html

	# 2) daemon + yardımcılar
	$(INSTALL_DIR) $(1)/usr/sbin $(1)/usr/libexec $(1)/etc/init.d $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/usr/sbin/h173d $(1)/usr/sbin/h173d
	$(INSTALL_BIN) ./files/usr/libexec/h173-ecdh $(1)/usr/libexec/h173-ecdh
	$(INSTALL_BIN) ./files/etc/init.d/h173 $(1)/etc/init.d/h173
	$(INSTALL_BIN) ./files/etc/uci-defaults/90-h173 $(1)/etc/uci-defaults/90-h173

	# 3) yapılandırma (modem web parolası)
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/h173 $(1)/etc/config/h173

	# 4) ucode modülleri (client/crypto/proto)
	$(INSTALL_DIR) $(1)/usr/share/ucode/h173
	$(INSTALL_DATA) ./files/usr/share/ucode/h173/*.uc $(1)/usr/share/ucode/h173/

	# 5) rpcd ACL (modem h173 ubus nesnesi + panelin kullandığı router ubus'ları)
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./files/usr/share/rpcd/acl.d/h173-modem.json $(1)/usr/share/rpcd/acl.d/
	$(INSTALL_DATA) ./files/usr/share/rpcd/acl.d/h173-panel.json $(1)/usr/share/rpcd/acl.d/
endef

define Package/h173dash/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
# uhttpd'ye /ubus ucu (yoksa ekle) — ubus-over-http için şart
if ! uci -q get uhttpd.main.ubus_prefix >/dev/null; then
	uci set uhttpd.main.ubus_prefix='/ubus'
	uci commit uhttpd
	/etc/init.d/uhttpd restart
fi
# ilk kurulum (enable + chmod 600 config)
[ -f /etc/uci-defaults/90-h173 ] && ( cd /tmp; sh /etc/uci-defaults/90-h173 && rm -f /etc/uci-defaults/90-h173 )
# daemon'ı etkinleştir + başlat
/etc/init.d/h173 enable
/etc/init.d/h173 start
# ACL'leri yükle (ubus erişimi)
/etc/init.d/rpcd restart
exit 0
endef

define Package/h173dash/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
/etc/init.d/h173 stop
/etc/init.d/h173 disable
exit 0
endef

$(eval $(call BuildPackage,h173dash))
