#!/system/bin/sh
# Read-only diagnosis for wireless CarPlay, the HUD services, the start-up
# warning timer and the USB drive log. Changes nothing on the unit: it only
# reads state and writes GEN5W-REPORT/DIAG-<n>.txt on this USB.
# Lines that can carry Bluetooth/Wi-Fi addresses, network names, keys,
# serials, phone/device names or media titles are dropped.
case "$0" in */*) cd "${0%/*}" || exit 1;; esac
DATA=${IT_DATA:-/data}
SYSFS=${IT_SYSFS:-/sys}
PROC=${IT_PROC:-/proc}
LOGS=$DATA/nemesis/logs
APPS=$DATA/nemesis/apps
[ "$(getprop sys.boot_completed 2>/dev/null)" = 1 ] || { echo 'REFUSED Android is not ready; plug the USB in again after boot'; exit 1; }
[ ! -L GEN5W-REPORT ] || exit 1
mkdir -p GEN5W-REPORT || exit 1
n=1
while [ -e "GEN5W-REPORT/DIAG-$n.txt" ] || [ -L "GEN5W-REPORT/DIAG-$n.txt" ]; do
    n=$((n + 1))
    [ "$n" -le 99 ] || { echo 'REFUSED GEN5W-REPORT already holds 99 diagnostic files'; exit 1; }
done
OUT=GEN5W-REPORT/DIAG-$n.txt
PRIV='([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}|[0-9A-Fa-f]{2}:\*\*|[Ss][Ss][Ii][Dd]|[Pp]assw|PASSW|[Pp]assphrase|[Pp]sk|PSK|[Ss]erial|SERIAL|[Ii]mei|IMEI|[Ii]ccid|ICCID|[Mm]sisdn|MSISDN|VIN[=: ]|vin[=: ]|DEVICE_NAME|[Dd]evice ?[Nn]ame|getName|FRQ:|BND:|ALBUM|TITLE|ARTIST|mArtist'
# Repeated status lines that fill the small log buffer and say nothing new.
NOISE='getState\(\)|Get Bonded Devices|getBondedDevices|getConnectedDevices\(\)|getConnectionState|mLruProcesses|BTAD|SplitScreenViewBTAudio|SplitBtAudioManager|BTA_BT_PLAYER|BTAudioView|onBtAudioStatusUpdate'
KEYS='Gen5w|gen5w|CarPlay|carplay|DiPO|Dipo|DIPO|Iap2|iap2|IAP2|PhoneProjection|PPManager|WPP|ProjectionManager|AndroidAuto|GPM|HfDeviceBTCM|BluetoothSocket|Rfcomm|RFCOMM|SoftAp|softap|hostapd|WifiService|WifiStateMachine|WifiHotspot|wpa_supplicant|wlan|ConsentScreen|NEMESIS|nemesis|AndroidRuntime|FATAL|Exception'
# Prints only the last $1 lines of file $2 (the unit has no tail): count, then skip.
last_lines() {
    local max=$1 file=$2 total=0 skip line
    while IFS= read -r line || [ -n "$line" ]; do total=$((total + 1)); done < "$file"
    skip=$((total - max))
    while IFS= read -r line || [ -n "$line" ]; do
        if [ "$skip" -gt 0 ]; then skip=$((skip - 1)); continue; fi
        print -r -- "$line"
    done < "$file"
}
clean() { grep -v -E "$PRIV"; }
section() { echo; echo "== $1"; }
{
    echo "# Gen5W KR diagnosis $n"
    section time; date
    section kit; cat BUILD-REVISION 2>/dev/null
    section 'installed packages'
    for f in "$APPS"/*/NEMESIS.data; do
        [ -f "$f" ] || continue
        id=${f%/NEMESIS.data}; id=${id##*/}
        v=$(grep -E '^package-version=' "$f" 2>/dev/null)
        echo "$id ${v#package-version=}"
    done
    section transaction; cat "$DATA/nemesis/gen5w-kr-integrated/state" 2>/dev/null
    section props
    getprop | grep -E 'boot_completed|ium|wifi|wlan|hotspot|softap|carplay|dipo|init\.svc\.(hostapd|wpa|dhcp|p2p|iprenew|bt|bluetooth)' | clean
    section permissions; ls "${IT_SYSTEM:-/system}/etc/permissions" 2>/dev/null | grep -i -E 'wireless|wifi|hotspot'
    section 'network interfaces'
    for i in "$SYSFS"/class/net/*; do
        [ -e "$i" ] || continue
        s=; [ -f "$i/operstate" ] && IFS= read -r s < "$i/operstate"
        echo "${i##*/} ${s:-?}"
    done
    section 'wifi driver modules'; grep -i -E 'dhd|bcm|wlan|8188|8192|8821|88x|rtl|ath' "$PROC/modules" 2>/dev/null
    section 'usb mounts'; grep -E 'usb|media_rw|/storage|fuse|vold' "$PROC/mounts" 2>/dev/null
    section 'usb block devices'
    while IFS=' ' read -r src point fs rest; do
        case "$src" in /dev/block/vold/*:*) ;; *) continue;; esac
        dev=${src##*/}
        real=$( (CDPATH= cd -P "$SYSFS/dev/block/$dev" 2>/dev/null && pwd -P) )
        echo "$dev $point $fs ${real:-unresolved}"
    done < "$PROC/mounts"
    section processes; ps | grep -i -E 'gen5w|dipo|iap2|gpm|hostapd|wpa|dhcp|bluetooth|projection|nemesis' | clean
    for f in "$LOGS"/gen5w.kr.*/*.log; do
        [ -f "$f" ] || continue
        section "service log ${f#$LOGS/} (last 400 lines)"
        ls -l "$f" 2>/dev/null
        last_lines 400 "$f" | clean
    done
    for f in "$LOGS"/usb-handler/usb-handler.log "$LOGS"/manager/update.log; do
        [ -f "$f" ] || continue
        section "nemesis log ${f#$LOGS/} (last 80 lines)"
        last_lines 80 "$f" | clean
    done
    section 'kernel log: wifi/usb'
    dmesg 2>/dev/null | grep -i -E 'wlan|dhd|wifi|sdio|bcm|usb|hostapd|firmware' | clean
    section 'logcat main (filtered)'
    logcat -d -v time 2>/dev/null | grep -E "$KEYS" | grep -v -E "$NOISE" | clean
    section 'logcat system (filtered)'
    logcat -d -v time -b system 2>/dev/null | grep -E "$KEYS" | grep -v -E "$NOISE" | clean
    section 'logcat buffer range (first and last line)'
    logcat -d -v time 2>/dev/null | clean | {
        IFS= read -r line; print -r -- "$line"
        while IFS= read -r line; do last=$line; done
        print -r -- "$last"
    }
} > "$OUT" 2>&1
sync
echo "SAVED GEN5W-REPORT/DIAG-$n.txt"
am broadcast -a com.hkmc.intent.action.TOAST -e com.hkmc.intent.extra.TOAST_MESSAGE "Gen5W KR: 진단 $n 저장 완료. USB를 빼도 됩니다." --ez com.hkmc.intent.extra.TOAST_POPUPSHOWING true >/dev/null 2>&1
exit 0
