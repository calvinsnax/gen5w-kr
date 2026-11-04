#!/system/bin/sh
# Read-only copy of the stock system files a new port needs, to the USB drive.
# Never remounts or writes /system or /data: it only reads /system and writes
# GEN5W-STOCK/ on the USB. Each copy is checked against the source by MD5.
# Copied files are the manufacturer's: keep them private, never attach them to
# a public issue. MANIFEST.txt holds only hashes and build facts (no VIN,
# serials, phone data, keys or Wi-Fi credentials).
export PATH=${GEN5W_TEST_PATH:-/sbin:/vendor/bin:/system/sbin:/system/bin:/system/xbin}
R=${STOCK_TEST_ROOT:-}
SYS=$R/system
USB=$R/storage/usb0
case "$0" in */*) [ -f "${0%/*}/NEMESIS.data" ] && USB=${0%/*};; esac
OUT=$USB/GEN5W-STOCK
MAN=$OUT/MANIFEST.txt

toast() {
    am broadcast -a com.hkmc.intent.action.TOAST -e com.hkmc.intent.extra.TOAST_MESSAGE "$1" \
        --ez com.hkmc.intent.extra.TOAST_POPUPSHOWING true >/dev/null 2>&1
}
sum() { local v; v=$(md5 "$1" 2>/dev/null) || return 1; set -- $v; [ -n "$1" ] && echo "$1"; }
fact() { echo "$1=$2" >> "$MAN"; }

[ "$(getprop sys.boot_completed 2>/dev/null)" = 1 ] || exit 1
[ -d "$USB" ] && [ ! -L "$USB" ] || exit 1
[ ! -L "$OUT" ] || { toast 'Gen5W KR 원본 수집: USB의 GEN5W-STOCK이 링크입니다. 중단합니다.'; exit 1; }
toast 'Gen5W KR 원본 수집 중입니다(수 분). 완료 알림까지 USB를 빼지 마세요.'
rm -rf "$OUT"
mkdir -p "$OUT/system" || { toast 'Gen5W KR 원본 수집 실패: USB에 쓸 수 없습니다.'; exit 1; }

: > "$MAN"
fact format 1
fact firmware "$(getprop ro.build.product)"
fact display_id "$(getprop ro.build.display.id)"
fact incremental "$(getprop ro.build.version.incremental)"
fact targetdir "$(getprop ro.mobis.targetdir)"
fact hardware "$(getprop ro.hardware)"
fact android "$(getprop ro.build.version.release)"
fact bootclasspath "$BOOTCLASSPATH"
# Signs that /system was changed by an installer before this copy.
[ -e "$SYS/etc/gen5w-kr-backup" ] && fact gen5w_backup present || fact gen5w_backup absent
APPS=
for d in $R/data/nemesis/apps/*; do [ -d "$d" ] && APPS="$APPS ${d##*/}"; done
fact nemesis_apps "${APPS# }"

# Targets the packages patch or read, their APK pairs, and the framework (boot
# classpath ODEX/JAR) that ODEX dependency checksums refer to.
LIST="app/Iap2ServerApp.odex app/Iap2ServerApp.apk
app/HKMC_DiPO.odex app/HKMC_DiPO.apk
app/HKMC_GPM.odex app/HKMC_GPM.apk
app/PhoneProjection.odex app/PhoneProjection.apk
app/HKMC_TAppService.odex app/HKMC_TAppService.apk
app/HKMC_TAppVRM.odex app/HKMC_TAppVRM.apk
priv-app/SystemUI.odex priv-app/SystemUI.apk
app/SystemUI.odex app/SystemUI.apk
lib/libCarPlayAudio.so lib/libCarPlayCore.so lib/libCarPlayUtils.so lib/libopus.so
wifi/bcmdhd.ko"
for f in $SYS/framework/*.odex $SYS/framework/*.jar; do
    [ -f "$f" ] && LIST="$LIST ${f#$SYS/}"
done

ok=0; bad=0; missing=0
copy() { # copy SRC REL: record "<status> <md5> <rel>"
    local src=$1 rel=$2 dst=$OUT/$2 want got
    if [ ! -f "$src" ] || [ -L "$src" ]; then
        echo "missing - $rel" >> "$MAN"; missing=$((missing + 1)); return
    fi
    mkdir -p "${dst%/*}"
    want=$(sum "$src")
    if [ -n "$want" ] && cp "$src" "$dst.part" 2>/dev/null && got=$(sum "$dst.part") && [ "$got" = "$want" ] &&
       mv "$dst.part" "$dst"; then
        echo "ok $want $rel" >> "$MAN"; ok=$((ok + 1))
    else
        rm -f "$dst.part"
        echo "copy-failed ${want:--} $rel" >> "$MAN"; bad=$((bad + 1))
    fi
}
for rel in $LIST; do copy "$SYS/$rel" "system/$rel"; done

# Product feature list the wireless package reads (not a personal file).
TD=$(getprop ro.mobis.targetdir)
case "$TD" in
    /system/*) copy "$R$TD/featurexml.cfg" "system${TD#/system}/featurexml.cfg";;
    *) echo "missing - targetdir/featurexml.cfg" >> "$MAN"; missing=$((missing + 1));;
esac

fact copied "$ok"
fact copy_failed "$bad"
fact missing "$missing"
if [ "$bad" = 0 ] && [ "$ok" -gt 0 ]; then fact result complete; else fact result incomplete; fi
sync
if [ "$bad" = 0 ] && [ "$ok" -gt 0 ]; then
    toast "Gen5W KR 원본 수집 완료: $ok개. USB를 빼도 됩니다. 파일은 공개 이슈에 올리지 마세요."
    exit 0
fi
toast "Gen5W KR 원본 수집 불완전: 실패 $bad개. USB 여유 공간을 확인하고 다시 실행하세요."
exit 1
