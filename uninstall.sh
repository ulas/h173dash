#!/bin/sh
# h173dash — kaldırma (ROUTER üzerinde çalıştırın)
#
# Daemon'ı durdurur, panel/daemon/ubus dosyalarını siler, kök URL'yi LuCI'ye
# geri döndürür, önbelleği temizler. Modem parolası (/etc/config/h173) varsayılan
# olarak KORUNUR; tümüyle silmek için:  sh uninstall.sh --purge
#
# Not: Paket olarak kurduysanız  'apk del h173dash'  (veya 'opkg remove h173dash')
# da kullanabilirsiniz; bu betik elle (install.sh ile) kurulanlar için de çalışır.
set -u

PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

echo "==> Daemon durduruluyor"
/etc/init.d/h173 stop 2>/dev/null || true
/etc/init.d/h173 disable 2>/dev/null || true

echo "==> Paket kaydı varsa kaldırılıyor"
if command -v apk >/dev/null 2>&1 && apk info -e h173dash >/dev/null 2>&1; then
	apk del h173dash 2>/dev/null || true
elif command -v opkg >/dev/null 2>&1 && opkg status h173dash >/dev/null 2>&1; then
	opkg remove h173dash 2>/dev/null || true
fi

echo "==> Dosyalar siliniyor"
rm -rf /www/dash
rm -f  /usr/sbin/h173d /usr/libexec/h173-ecdh /etc/init.d/h173 \
       /etc/uci-defaults/90-h173
rm -rf /usr/share/ucode/h173
rm -f  /usr/share/rpcd/acl.d/h173-modem.json /usr/share/rpcd/acl.d/h173-panel.json

# kök URL: panel yönlendirmesini LuCI'ye geri döndür
if [ -f /www/index.html ] && grep -q "/dash/" /www/index.html 2>/dev/null; then
	echo "==> Kök URL LuCI'ye döndürülüyor"
	cat > /www/index.html <<'HTML'
<!DOCTYPE html><html><head><meta http-equiv="refresh" content="0; url=/cgi-bin/luci/"></head>
<body><script>location.replace('/cgi-bin/luci/')</script></body></html>
HTML
fi

# modem parolası/yapılandırması
if [ "$PURGE" = 1 ]; then
	echo "==> Yapılandırma siliniyor (--purge)"
	rm -f /etc/config/h173
	uci -q delete uhttpd.main.ubus_prefix 2>/dev/null && uci commit uhttpd || true
else
	echo "==> /etc/config/h173 korundu (yeniden kurulumda parola kalsın). Silmek için --purge."
fi
# ubus_prefix'i --purge dışında bırakıyoruz: LuCI de /ubus kullanır.

echo "==> Önbellek temizleniyor, servisler yenileniyor"
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache 2>/dev/null || true
/etc/init.d/rpcd restart 2>/dev/null || true
/etc/init.d/uhttpd restart 2>/dev/null || true

echo ""
echo "==> Kaldırıldı. Tarayıcıyı Ctrl+Shift+R ile yenileyin."
