#!/bin/sh
# h173dash — GitHub'dan kurulum (ROUTER üzerinde çalıştırın)
#
# Derleme gerektirmez: panel saf Vue dist + ucode daemon'dır. Betik bağımlılıkları
# apk ile kurar, repo arşivini indirip dosyaları yerleştirir, ubus'u ayarlar,
# daemon'ı etkinleştirir. Mevcut /etc/config/h173 (modem parolası) KORUNUR.
#
# Kullanım (router SSH içinde):
#   REPO=ulas/h173dash sh install.sh
#   sh install.sh ulas/h173dash [dal]
#
# Tek satırda:
#   wget -qO- https://raw.githubusercontent.com/ulas/h173dash/main/install.sh \
#     | REPO=ulas/h173dash sh
set -eu

REPO="${1:-${REPO:-ulas/h173dash}}"
BRANCH="${2:-${BRANCH:-main}}"

case "$REPO" in */*) : ;; *) echo "HATA: REPO 'kullanıcı/depo' olmalı"; exit 1 ;; esac

TMP="/tmp/h173dash.$$"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT

fetch() {
  if command -v wget >/dev/null 2>&1; then wget -qO "$2" "$1" || wget --no-check-certificate -qO "$2" "$1"
  elif command -v uclient-fetch >/dev/null 2>&1; then uclient-fetch -qO "$2" "$1" || uclient-fetch --no-check-certificate -qO "$2" "$1"
  elif command -v curl >/dev/null 2>&1; then curl -fsSL "$1" -o "$2"
  else echo "HATA: wget / uclient-fetch / curl yok."; exit 1; fi
}

# 1) Bağımlılıklar (daemon için ucode modülleri + rpcd köprüleri)
echo "==> Bağımlılıklar kuruluyor (varsa atlanır)"
DEPS="rpcd uhttpd uhttpd-mod-ubus rpcd-mod-file rpcd-mod-iwinfo rpcd-mod-luci \
ucode ucode-mod-digest ucode-mod-fs ucode-mod-uloop ucode-mod-ubus ucode-mod-uci ucode-mod-socket"
if command -v apk >/dev/null 2>&1; then
	apk update 2>/dev/null || true
	apk add $DEPS 2>/dev/null || echo "   (bazı paketler zaten kurulu veya bulunamadı — devam)"
else
	opkg update 2>/dev/null || true
	opkg install $DEPS 2>/dev/null || echo "   (bazı paketler zaten kurulu veya bulunamadı — devam)"
fi

# 2) Arşivi indir (main yoksa master)
SRC=""
for br in "$BRANCH" master; do
	URL="https://codeload.github.com/$REPO/tar.gz/refs/heads/$br"
	echo "==> İndiriliyor: $URL"
	if fetch "$URL" "$TMP/src.tgz" && tar xzf "$TMP/src.tgz" -C "$TMP" 2>/dev/null; then
		SRC="$(find "$TMP" -maxdepth 1 -type d ! -path "$TMP" | head -1)"
		[ -n "$SRC" ] && [ -d "$SRC/files/www/dash" ] && { BRANCH="$br"; break; }
		SRC=""
	fi
done
[ -n "$SRC" ] || { echo "HATA: Arşivde files/www/dash yok — htdocs/dist commit edilmiş mi? Dal doğru mu?"; exit 1; }
F="$SRC/files"
echo "==> Kaynak: $F ($BRANCH)"

# 3) Dosyaları yerleştir
echo "==> Panel + daemon yerleştiriliyor"
mkdir -p /www/dash /usr/sbin /usr/libexec /etc/init.d /etc/uci-defaults \
         /usr/share/ucode/h173 /usr/share/rpcd/acl.d /etc/config
cp -rf "$F/www/dash/." /www/dash/
cp -f  "$F/www/index.html" /www/index.html
cp -f  "$F/usr/sbin/h173d" /usr/sbin/h173d
cp -f  "$F/usr/libexec/h173-ecdh" /usr/libexec/h173-ecdh
cp -f  "$F/etc/init.d/h173" /etc/init.d/h173
cp -f  "$F/etc/uci-defaults/90-h173" /etc/uci-defaults/90-h173
cp -f  "$F"/usr/share/ucode/h173/*.uc /usr/share/ucode/h173/
cp -f  "$F"/usr/share/rpcd/acl.d/h173-*.json /usr/share/rpcd/acl.d/
chmod 755 /usr/sbin/h173d /usr/libexec/h173-ecdh /etc/init.d/h173 /etc/uci-defaults/90-h173

# config: mevcutsa KORU (parola), yoksa varsayılanı koy
if [ ! -f /etc/config/h173 ]; then
	cp -f "$F/etc/config/h173" /etc/config/h173
	echo "   /etc/config/h173 oluşturuldu — modem parolasını ayarlayın (aşağıda)"
else
	echo "   /etc/config/h173 korundu (mevcut ayarlar/parola)"
fi
chmod 600 /etc/config/h173

# 4) ubus + daemon
echo "==> ubus köprüsü + daemon ayarlanıyor"
if ! uci -q get uhttpd.main.ubus_prefix >/dev/null; then
	uci set uhttpd.main.ubus_prefix='/ubus'; uci commit uhttpd
fi
[ -f /etc/uci-defaults/90-h173 ] && ( cd /tmp; sh /etc/uci-defaults/90-h173 && rm -f /etc/uci-defaults/90-h173 )
/etc/init.d/h173 enable
# İlk kurulumda servis henüz çalışmadığından 'restart' önce 'stop' dener ve procd
# 'Command failed: Not found' (zararsız) yazar — bu yüzden stop'u susturup start'a düşüyoruz.
/etc/init.d/h173 restart >/dev/null 2>&1 || /etc/init.d/h173 start
/etc/init.d/rpcd restart
/etc/init.d/uhttpd restart

# 25.x ipaddr'ı CIDR ile dönebilir (192.168.1.1/24) — maske kısmını at.
IP="$(uci -q get network.lan.ipaddr 2>/dev/null || echo 192.168.1.1)"; IP="${IP%%/*}"
echo ""
echo "==> Bitti. Panel:  http://$IP/   (giriş: root + router parolası)"
echo "    Modem parolası ayarlı değilse:"
echo "      uci set h173.main.password='MODEM_WEB_SIFRESI'; uci commit h173; /etc/init.d/h173 restart"
echo "    Modem köprü modunda farklı IP/kullanıcıdaysa host/username'i de ayarlayın."
