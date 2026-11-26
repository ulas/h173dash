#!/bin/sh
# h173dash — .apk / .ipk derleme (OpenWrt SDK ile)
# Panel saf ucode + statik www (PKGARCH:=all, noarch) olduğundan HERHANGİ bir
# güncel OpenWrt SDK (apk nesli: 24.10+/snapshot) .apk üretebilir; çıktı
# mimariden bağımsızdır ve cihaza kurulur.
#
# Kullanım:  ./build.sh /yol/openwrt-sdk-dizini
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
SDK="${1:-}"
[ -n "$SDK" ] || { echo "Kullanım: $0 <OpenWrt-SDK-dizini>"; exit 1; }
[ -x "$SDK/scripts/feeds" ] || { echo "HATA: Geçerli bir OpenWrt SDK değil: $SDK"; exit 1; }

echo "==> Paket SDK'ya kopyalanıyor"
rm -rf "$SDK/package/h173dash"
mkdir -p "$SDK/package/h173dash"
cp -r "$HERE/Makefile" "$HERE/files" "$SDK/package/h173dash/"

echo "==> Derleniyor"
cd "$SDK"
./scripts/feeds update -a  >/dev/null 2>&1 || true
./scripts/feeds install -a >/dev/null 2>&1 || true
[ -f .config ] || make defconfig
make package/h173dash/compile V=s

echo "==> Çıktılar toplanıyor"
OUT="$HERE/dist-pkg"; mkdir -p "$OUT"; found=0
for pat in 'h173dash_*.apk' 'h173dash_*.ipk'; do
	for f in $(find "$SDK/bin" -name "$pat" 2>/dev/null); do cp "$f" "$OUT/"; echo "   $(basename "$f")"; found=1; done
done
[ "$found" = 1 ] || { echo "HATA: çıktı bulunamadı — derleme loglarına bakın."; exit 1; }
echo "==> Hazır: $OUT/"
