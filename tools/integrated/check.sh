#!/system/bin/sh
# Read-only pre-install check. Changes nothing on the unit: no remount, no
# package install, no Wi-Fi toggle, no setprop. Writes GEN5W-REPORT/CHECK.txt
# (facts) and CHECK.md (verdict) to the USB only. Fixed allowlist: properties,
# file hashes, verifier verdicts, package ids. No VIN, serials, phone data,
# hotspot credentials, keys or /data file contents.
#
# check.sh --verify (run by the safe installers before any change): repeat the
# check into CHECK-NOW.txt and pass only if CHECK.txt exists, came from the same
# build, said "install", and every stable fact still matches exactly.
case "$0" in */*) cd "${0%/*}" || exit 1;; esac
export PATH=${CK_TEST_PATH:-/sbin:/vendor/bin:/system/sbin:/system/bin:/system/xbin}
DATA=${IT_DATA:-/data}
SYS=${IT_SYSTEM:-/system}
APPS=$DATA/nemesis/apps
TX=$DATA/nemesis/gen5w-kr-integrated
BOOTGUARD=$DATA/nemesis/gen5wkr.bootguard
OUT=GEN5W-REPORT
MODE=check
[ "$1" = --verify ] && MODE=verify
[ ! -L "$OUT" ] || exit 1
mkdir -p "$OUT" || exit 1
for f in CHECK.txt CHECK.md CHECK-NOW.txt; do [ ! -L "$OUT/$f" ] || exit 1; done
if [ "$MODE" = verify ]; then
    [ -f "$OUT/CHECK.txt" ] || { echo 'REFUSED no pre-install check report (GEN5W-REPORT/CHECK.txt): run gen5w-kr-check first'; exit 1; }
    FACTS=$OUT/CHECK-NOW.txt
else
    FACTS=$OUT/CHECK.txt
fi
: > "$FACTS" || exit 1

fact() { echo "$1=$2" >> "$FACTS"; }
# Shell builtins only: the head unit has no tr, cut, sed or head.
CR=$'\r'
clean() {
    local all= line
    while IFS= read -r line || [ -n "$line" ]; do all=$all$line; done
    all=${all//"$CR"/}
    all=${all:0:96}
    print -r -- "${all//[!a-zA-Z0-9_.:\/ -]/?}"
}
first_line() { local line=; IFS= read -r line < "$1" || [ -n "$line" ] || return 1; print -r -- "$line"; }
prop() { getprop "$1" 2>/dev/null | clean; }
digest() { local v; v=$(md5 "$1" 2>/dev/null) || return 1; set -- $v; echo "$1"; }
check_progress() {
    local am_bin=${CK_TEST_AM:-/system/bin/am}
    [ "$MODE" = check ] && [ -f GEN5W-CHECK-ONLY ] && [ -x "$am_bin" ] || return 0
    "$am_bin" broadcast -a com.hkmc.intent.action.TOAST \
        -e com.hkmc.intent.extra.TOAST_MESSAGE "점검 ($1/5) $2. 완료까지 USB를 빼지 마세요." \
        --ez com.hkmc.intent.extra.TOAST_POPUPSHOWING true >/dev/null 2>&1 || true
}

# Verdict of the bundled verifiers for one target: stock-v039, patched-v039,
# stock-v035, patched-v035, unknown or missing. Each verifier is TOOL:FIRMWARE;
# vehicle profiles of one firmware (e.g. v039 and v039gl3) report the same name.
verify() {
    local file=$SYS/$1 dir=checks/$2/bin pair tool label
    [ -f "$file" ] && [ ! -L "$file" ] || { echo missing; return; }
    shift 2
    for pair in "$@"; do
        tool=$dir/${pair%%:*}; label=${pair#*:}
        [ -f "$tool" ] && [ ! -L "$tool" ] || continue
        chmod 755 "$tool" 2>/dev/null
        "$tool" original "$file" >/dev/null 2>&1 && { echo "stock-$label"; return; }
        "$tool" patched "$file" >/dev/null 2>&1 && { echo "patched-$label"; return; }
    done
    echo unknown
}
# iAP2 has two distinct historical patches. Prefer the current capability-only
# verifier and report the older service-control shim separately.
verify_iap2() {
    local file=$SYS/app/Iap2ServerApp.odex dir=checks/gen5w.kr.bridge/bin pair version label kind tool
    [ -f "$file" ] && [ ! -L "$file" ] || { echo missing; return; }
    for pair in v039:v039 v039gl3:v039 v035:v035; do
        version=${pair%%:*}; label=${pair#*:}
        for kind in route iap2; do
            if [ "$kind" = route ]; then tool=$dir/iap2-route-patch-$version; else tool=$dir/iap2-patch-$version; fi
            [ -f "$tool" ] && [ ! -L "$tool" ] && chmod 755 "$tool" 2>/dev/null
            [ -x "$tool" ] || continue
            "$tool" original "$file" >/dev/null 2>&1 && { echo "stock-$label"; return; }
            if "$tool" patched "$file" >/dev/null 2>&1; then
                if [ "$kind" = route ]; then echo "route-capability-$label"; else echo "legacy-control-$label"; fi
                return
            fi
        done
    done
    echo unknown
}
# Boot-critical files no edition changes: compare with the stock SHA-256 only.
# Arguments after the path are SHA256:FIRMWARE.
verify_hash() {
    local file=$SYS/$1 tool=checks/gen5w.kr.timer/bin/sha256-check pair
    [ -f "$file" ] && [ ! -L "$file" ] || { echo missing; return; }
    [ -f "$tool" ] && [ ! -L "$tool" ] && chmod 755 "$tool" 2>/dev/null || { echo unknown; return; }
    shift
    for pair in "$@"; do
        "$tool" verify "$file" "${pair%%:*}" >/dev/null 2>&1 && { echo "stock-${pair#*:}"; return; }
    done
    echo unknown
}
# Passive only: the installer may briefly turn Wi-Fi on to look; this check never does.
SYSFS=${CK_TEST_SYSFS:-/sys}
wifi_seen() {
    local entry class
    for entry in "$SYSFS"/class/net/wlan*; do [ -e "$entry" ] && { echo yes; return; }; done
    for entry in "$SYSFS"/bus/sdio/devices/*/class; do
        [ -r "$entry" ] || continue
        IFS= read -r class < "$entry"
        [ "$class" = 0x07 ] && { echo yes; return; }
    done
    case "$(dmesg 2>/dev/null)" in *'Firmware up'*) echo yes;; *) echo unknown;; esac
}
# Supported USB Wi-Fi dongle plugged in (same IDs as the dongle edition).
dongle_seen() {
    local v p vid pid
    for v in "$SYSFS"/bus/usb/devices/*/idVendor; do
        [ -f "$v" ] || continue
        p=${v%idVendor}idProduct
        [ -f "$p" ] || continue
        IFS= read -r vid < "$v"; IFS= read -r pid < "$p"
        case "$vid:$pid" in
            0cf3:9271|0cf3:7010|0cf3:7015|0cf3:1006|0846:9030|0846:9018|07d1:3a10) echo yes; return;;
        esac
    done
    echo no
}
wireless_code() {
    local a
    for a in "$SYS/app/HKMC_DiPO.odex" "$SYS/app/PhoneProjection.odex" "$SYS/app/Iap2ServerApp.odex"; do
        [ -f "$a" ] || continue
        grep -aqE "carplay_wireless|androidauto_wireless|ConnectivitySSID" "$a" 2>/dev/null && { echo yes; return; }
    done
    echo no
}

# --- facts -----------------------------------------------------------------
check_progress 1 '차량 정보 확인 중'
fact bundle_revision "$(first_line BUILD-REVISION 2>/dev/null | clean)"
fact firmware "$(prop ro.build.product)"
fact display_id "$(prop ro.build.display.id)"
fact incremental "$(prop ro.build.version.incremental)"
fact targetdir "$(prop ro.mobis.targetdir)"
fact hardware "$(prop ro.hardware)"
fact android "$(prop ro.build.version.release)"
[ -x "$SYS/xbin/nemesis" ] && fact nemesis yes || fact nemesis no
# "nemesis version" exists from 1.16; 1.15 has no such command.
NEM_VER=$("$SYS/xbin/nemesis" version 2>/dev/null | clean)
case "$NEM_VER" in ''|*[!0-9.]*) NEM_VER=unknown;; esac
fact nemesis_version "$NEM_VER"

check_progress 2 '순정 파일 확인 중'
S_HOTSPOT=$(verify_hash framework/services.odex 63cf432dd4597a916ce9faa0c26b5f7ad29affba3976cf4c8cf316dc16107c4f:v039 01f4f2da6236fd89991ab1ccaf58509c45e6e35cd46cef1970ad463c6984a402:v039 64fe8286ff39ba52223bf04d7c98fe7e4c2579ad06a090f7a4b80a34faa1e0ca:v035)
S_SYSUI=$(verify_hash priv-app/SystemUI.odex 97e7e258df34d76ed61a714f83de4bf0fbc3d6b6188055c941ad2689f72595af:v039 5d9dbd223d149326522a3ba1b276c5f443024c502ed422b3344d5c47e3a603a3:v039 3de39c29f10c8db3ec786f59378f5b716b04e6be473b42989f40ef828ef0867b:v035)
S_AUDIO=$(verify lib/libCarPlayAudio.so gen5w.kr.audio audio-patch:v039 audio-patch-v039gl3:v039 audio-patch-v035:v035)
S_IAP2=$(verify_iap2)
S_DIPO=$(verify app/HKMC_DiPO.odex gen5w.kr.bridge dipo-patch-v039:v039 dipo-patch-v039gl3:v039 dipo-patch-v035:v035)
S_GPM=$(verify app/HKMC_GPM.odex gen5w.kr.bridge gpm-patch-v039:v039 gpm-patch-v039gl3:v039 gpm-patch-v035:v035)
fact services_odex "$S_HOTSPOT"
fact systemui_odex "$S_SYSUI"
fact carplay_audio_so "$S_AUDIO"
fact iap2_odex "$S_IAP2"
fact dipo_odex "$S_DIPO"
fact gpm_odex "$S_GPM"
for f in framework/services.odex priv-app/SystemUI.odex lib/libCarPlayAudio.so app/Iap2ServerApp.odex app/HKMC_DiPO.odex app/HKMC_GPM.odex; do
    [ -f "$SYS/$f" ] && fact "md5:$f" "$(digest "$SYS/$f")"
done
# Every target unknown (none missing, none patched) means the whole build differs
# from every registered stock set: an unregistered vehicle/build, i.e. a new
# port. Re-flashing the official update cannot turn it into a registered one.
UNREGISTERED=no
case "$S_HOTSPOT:$S_SYSUI:$S_AUDIO:$S_IAP2:$S_DIPO:$S_GPM" in
    unknown:unknown:unknown:unknown:unknown:unknown) UNREGISTERED=yes;; esac
fact unregistered_build "$UNREGISTERED"

check_progress 3 'Wi-Fi와 동글 확인 중'
W_CODE=$(wireless_code)
W_HW=$(wifi_seen)
fact wireless_code "$W_CODE"
fact wifi_hardware_seen "$W_HW"
D_SEEN=$(dongle_seen)
# Built-in Wi-Fi shows up only while Wi-Fi is on. If it is off and no dongle is
# plugged in, turn it on for up to 8 s and off again, as the installer does.
# Settings only (svc wifi); no file is written.
W_PROBE=skipped
[ "$MODE" = verify ] || [ -f GEN5W-CHECK-ONLY ] || [ ! -x /system/bin/am ] || /system/bin/am broadcast -a com.hkmc.intent.action.TOAST -e com.hkmc.intent.extra.TOAST_MESSAGE "Gen5W KR 점검 중입니다(최대 1분). 완료 알림이 뜰 때까지 USB를 빼지 마세요." --ez com.hkmc.intent.extra.TOAST_POPUPSHOWING true >/dev/null 2>&1
if [ "$W_HW" != yes ] && [ "$D_SEEN" != yes ] && [ "$(settings get global wifi_on 2>/dev/null | clean)" = 0 ] &&
   command -v svc >/dev/null 2>&1; then
    W_PROBE=not-found
    # Always turn it off again, even if enable reported an error.
    svc wifi enable >/dev/null 2>&1
    n=0
    while [ $n -lt 8 ]; do
        [ "$(wifi_seen)" = yes ] && { W_PROBE=found; W_HW=yes; break; }
        sleep 1; n=$((n + 1))
    done
    svc wifi disable >/dev/null 2>&1
    n=0
    while [ "$(settings get global wifi_on 2>/dev/null | clean)" != 0 ]; do
        [ $n -lt 8 ] || { W_PROBE=still-on; break; }
        sleep 1; n=$((n + 1))
    done
fi
fact wifi_probe "$W_PROBE"
fact wifi_hardware_seen_after_probe "$W_HW"
fact dongle_seen "$D_SEEN"
D_INST=no
[ -f "$APPS/gen5w.kr.dongle/NEMESIS.data" ] && D_INST=yes
fact dongle_installed "$D_INST"
# Which download fits this car. With the dongle edition installed, wlan0 may be
# the dongle, so the built-in result is not used.
if [ "$D_INST" = yes ]; then EDITION=dongle; EDITION_WHY=installed
elif [ "$W_HW" = yes ]; then EDITION=standard; EDITION_WHY=builtin
elif [ "$D_SEEN" = yes ]; then EDITION=dongle; EDITION_WHY=dongle-only
else EDITION=standard; EDITION_WHY=unknown; fi
fact recommend "$EDITION"
fact wifi_on "$(settings get global wifi_on 2>/dev/null | clean)"
fact ium_support "$(prop persist.ium.support)"
for x in com.hkmc.software.connectivity.carplay_wireless.xml com.hkmc.software.connectivity.androidauto_wireless.xml com.hkmc.software.wifihotspot.xml android.hardware.wifi.xml; do
    [ -e "$SYS/etc/permissions/$x" ] && fact "perm:$x" present || fact "perm:$x" absent
done
FX=$(prop ro.mobis.targetdir)
if [ -n "$FX" ] && [ -f "$FX/featurexml.cfg" ]; then
    fact featurexml_strip_lines "$(grep -v '^#' "$FX/featurexml.cfg" 2>/dev/null | grep -cE 'carplay_wireless.xml|androidauto_wireless.xml|wifihotspot.xml')"
else
    fact featurexml_strip_lines unknown
fi

check_progress 4 '설치 상태 확인 중'
PKGS=
if [ -d "$APPS" ]; then
    for d in "$APPS"/*; do
        [ -e "$d" ] || continue
        n=${d##*/}
        case "$n" in *[!a-zA-Z0-9._-]*) n='?';; esac
        PKGS="$PKGS $n"
    done
fi
fact nemesis_packages "${PKGS# }"
OTHER=
for n in $PKGS; do
    # NEMESIS 1.16 installs its own update-monitor and usb-handler packages.
    case "$n" in gen5w.kr.*|nemesis.update-monitor|usb-handler) ;; *) OTHER="$OTHER $n";; esac
done
BACKUPS=
for d in "$SYS"/etc/gen5w-kr-backup/*; do [ -e "$d" ] && BACKUPS="$BACKUPS ${d##*/}"; done
fact gen5w_backups "${BACKUPS# }"
TXSTATE=none
[ -f "$TX/state" ] && TXSTATE=$(first_line "$TX/state" | clean)
fact transaction "$TXSTATE"
TXSNAPSHOT=missing
[ -f "$TX/prior/complete" ] && TXSNAPSHOT=complete
fact transaction_snapshot "$TXSNAPSHOT"
GUARD=none
if [ -d "$BOOTGUARD" ]; then
    GUARD=present
    [ -f "$BOOTGUARD/armed" ] && GUARD=armed
    [ -e "$BOOTGUARD/recovery-required" ] && GUARD=recovery-required
    fact bootguard_count "$(first_line "$BOOTGUARD/count" 2>/dev/null | clean)"
    fact bootguard_max "$(first_line "$BOOTGUARD/max" 2>/dev/null | clean)"
fi
fact bootguard "$GUARD"
[ -e "$DATA/nemesis/gen5wkr.wireless-disabled" ] && fact wireless_disabled_marker yes || fact wireless_disabled_marker no
[ -e "$DATA/nemesis/gen5wkr.apguard.off" ] && APGUARD_OFF=yes || APGUARD_OFF=no
fact apguard_off $APGUARD_OFF
df "$SYS" "$DATA" /cache 2>/dev/null | while IFS= read -r line; do echo "df=$(echo "$line" | clean)" >> "$FACTS"; done

# --- verdict ---------------------------------------------------------------
BLOCK=; WARN=; WL=
block() { BLOCK="$BLOCK
- $1"; }
warn() { WARN="$WARN
- $1"; }
owned() { [ -e "$SYS/etc/gen5w-kr-backup/$1" ]; }
is_v035() { case "$1" in *-v035) return 0;; esac; return 1; }

if [ "$UNREGISTERED" = yes ]; then
    block "순정 파일 6개가 모두 등록된 원본과 다릅니다. 이 차종·빌드($(prop ro.build.product))는 아직 지원 목록에 없는 새 포트로 보이며, 이 파일들에 맞춘 패치가 없습니다. 공식 업데이트를 다시 해도 해결되지 않습니다. 설치하지 말고 GEN5W-REPORT의 CHECK.txt·CHECK.md를 차량 지원 요청에 첨부하세요."
fi
for s in "$S_IAP2" "$S_DIPO" "$S_GPM" "$S_SYSUI"; do
    is_v035 "$s" && { block '펌웨어가 V035로 보입니다. 공식 V039로 먼저 업데이트하세요.'; break; }
done
[ "$UNREGISTERED" = yes ] || for pair in "Iap2ServerApp:$S_IAP2" "HKMC_DiPO:$S_DIPO" "HKMC_GPM:$S_GPM"; do
    case "${pair#*:}" in
        stock-v039) ;;
        patched-v039) owned bridge || block "${pair%%:*} 파일이 이미 바뀌어 있는데 이 도구의 백업이 없습니다. 공식 V039 업데이트로 순정 복구 후 다시 점검하세요.";;
        route-capability-v039) owned bridge || block 'Iap2ServerApp.odex의 RouteGuidance 기능 선언이 바뀌어 있는데 순정 백업이 없습니다. 공식 V039 업데이트로 순정 복구 후 다시 점검하세요.';;
        legacy-control-v039) owned bridge || block 'Iap2ServerApp.odex에 이전 무선 제어 수정이 있지만 순정 백업이 없습니다. 공식 V039 업데이트로 순정 복구 후 다시 점검하세요.';;
        *-v035) ;;
        *) if owned bridge; then warn "${pair%%:*} 파일이 이전 버전 패치 상태로 보입니다(${pair#*:}). 설치기가 백업으로 판단합니다."
           else block "${pair%%:*} 파일을 순정 V039로 확인하지 못했습니다(${pair#*:}). 공식 V039 업데이트로 순정 복구 후 다시 점검하세요."; fi;;
    esac
done
# This tool never changes these two; a non-stock copy came from something else.
[ "$UNREGISTERED" = yes ] || case "$S_SYSUI" in
    stock-*) ;;
    *) block "SystemUI(시동 동의 화면)가 순정이 아닙니다($S_SYSUI). 다른 도구가 바꾼 상태일 수 있습니다. 공식 V039 업데이트로 순정 복구 후 다시 점검하세요.";;
esac
[ "$UNREGISTERED" = yes ] || case "$S_HOTSPOT" in
    stock-*) ;;
    *) block "services.odex(시스템 핵심)가 순정이 아닙니다($S_HOTSPOT). 다른 도구가 바꾼 상태일 수 있습니다. 공식 업데이트로 순정 복구 후 다시 점검하세요.";;
esac
[ "$APGUARD_OFF" = yes ] && warn '핫스팟을 켜는 도중 재부팅이 3번 연속 일어나 무선이 자동으로 꺼져 있습니다(유선은 동작). 다시 설치하면 다시 켜집니다. 재발하면 무선을 쓰지 마세요.'
[ "$W_PROBE" = still-on ] && warn 'Wi-Fi 확인 후 Wi-Fi가 꺼지지 않았습니다. 설정에서 Wi-Fi를 끄세요.'
[ "$GUARD" = recovery-required ] && block '이전 부트가드가 복구 필요 상태입니다. 공식 V039 업데이트를 먼저 하세요.'
case "$TXSTATE" in none|committed|rolled-back) ;;
    recovery-required) block '이전 설치 작업을 복구해야 합니다(state=recovery-required). 복구 상태를 확인한 뒤 다시 점검하세요.';;
    applying|removing|recovering)
        if [ "$TXSNAPSHOT" = complete ]; then
            warn "이전 설치 작업이 끝나지 않은 흔적이 있습니다(state=$TXSTATE). 설치하면 먼저 이 작업을 복구합니다."
        else
            block "이전 설치 작업의 백업이 완전하지 않습니다(state=$TXSTATE). 복구 상태를 확인한 뒤 다시 점검하세요."
        fi;;
    capturing) warn '이전 백업 수집이 중단됐습니다. 설치하면 백업을 다시 수집합니다.';;
    *) block "알 수 없는 설치 상태입니다(state=$TXSTATE). 복구 자료를 보존하고 상태를 확인하세요.";; esac
# NEMESIS Store packages that change the same things as ours (also refused in our depends=).
CLASH=
for n in $OTHER; do
    case "$n" in wireless.projection|local.hkmc.factory82|enhanced.projection|projection.tbt) CLASH="$CLASH $n";; esac
done
fact store_conflicts "${CLASH# }"
[ -n "$CLASH" ] && block "같은 기능을 바꾸는 스토어 패키지가 설치돼 있습니다:$CLASH. NEMESIS Manager의 My Packages에서 먼저 제거한 뒤 다시 점검하세요."
[ -n "$OTHER" ] && warn "다른 NEMESIS 패키지가 있습니다:$OTHER. 이전 Leafia 패키지(wireless.carplay.aa)는 설치 중 백업 후 제거됩니다. 그 외는 그대로 둡니다."
[ -e "$SYS/etc/permissions/android.hardware.wifi.xml" ] && warn 'Wi-Fi 클라이언트 선언(android.hardware.wifi.xml)이 이미 있습니다. 순정에 원래 있던 것인지 확인이 필요합니다. 벽돌 차량에 추가됐던 파일입니다.'

if [ "$W_CODE" != yes ]; then
    WL='순정 앱에서 무선 코드를 찾지 못했습니다. 설치해도 무선은 켜지지 않고 유선 전용(HUD 등)으로 설치됩니다.'
else
    if [ -z "$WL" ]; then
        case "$S_AUDIO" in stock-v039|patched-v039) ;;
            *) warn "libCarPlayAudio.so를 확인하지 못했습니다($S_AUDIO). 무선 오디오 보정은 건너뜁니다.";; esac
        if [ "$W_HW" = yes ]; then
            WL='무선 조건 충족: 무선 코드와 Wi-Fi 장치가 확인됐습니다.'
        else
            WL='무선 코드는 있지만 내장 Wi-Fi를 확인하지 못했습니다. Wi-Fi를 잠깐 켜서 확인했는데도 안 보이면 내장 Wi-Fi가 없는 차일 수 있습니다.'
        fi
    fi
fi

if [ -n "$BLOCK" ]; then fact verdict block; else fact verdict install; fi

if [ "$MODE" = verify ]; then
    # Volatile values (Wi-Fi power, free space, boot counter) are not compared.
    stable() { grep -vE '^(wifi_on|wifi_hardware_seen|wifi_hardware_seen_after_probe|wifi_probe|dongle_seen|recommend|df|bootguard_count)=' "$1"; }
    SAVED=$OUT/CHECK.txt
    grep -qx 'verdict=install' "$SAVED" || { echo 'REFUSED pre-install check report did not say install'; exit 1; }
    [ -z "$BLOCK" ] || { echo 'REFUSED unit no longer passes the pre-install check'; exit 1; }
    bad=0
    stable "$FACTS" > "$OUT/CHECK-NOW.stable"
    stable "$SAVED" > "$OUT/CHECK-SAVED.stable"
    while IFS= read -r line; do
        grep -qxF "$line" "$OUT/CHECK-SAVED.stable" || { echo "MISMATCH now: $line"; bad=1; }
    done < "$OUT/CHECK-NOW.stable"
    while IFS= read -r line; do
        grep -qxF "$line" "$OUT/CHECK-NOW.stable" || { echo "MISMATCH report: $line"; bad=1; }
    done < "$OUT/CHECK-SAVED.stable"
    rm -f "$OUT/CHECK-NOW.stable" "$OUT/CHECK-SAVED.stable"
    sync
    [ "$bad" = 0 ] || { echo 'REFUSED unit state differs from the pre-install check report: run gen5w-kr-check again'; exit 1; }
    echo 'CHECK verified: unit matches the pre-install check report'
    exit 0
fi

check_progress 5 '점검 결과 저장 중'
{
    echo '# 설치 전 점검 결과'
    echo
    echo "- 펌웨어: $(prop ro.build.product) / $(prop ro.build.display.id)"
    REV=$(first_line BUILD-REVISION 2>/dev/null)
    echo "- 점검 도구 버전: ${REV:0:7}"
    echo "- NEMESIS 버전: $NEM_VER"
    echo
    if [ -n "$BLOCK" ]; then
        echo '## 판정: 설치하지 마세요'
        echo "$BLOCK"
    else
        echo '## 판정: 설치 가능'
        echo
        if [ "$EDITION" = dongle ]; then
            echo '### 받을 파일: 동글형 `gen5w-kr-dongle.zip`'
        else
            echo '### 받을 파일: 기본형 `gen5w-kr-standard.zip`'
        fi
        echo
        case "$EDITION_WHY" in
            installed) echo '- 이미 동글형이 설치되어 있습니다. 업데이트도 동글형으로 하세요. 기본형으로 바꾸면 동글 설정을 지우고 내장 Wi-Fi로 돌아갑니다.';;
            builtin) echo '- 내장 Wi-Fi가 확인됐습니다. 동글이 필요 없습니다.';;
            dongle-only) echo '- 내장 Wi-Fi는 확인되지 않았고 지원 USB Wi-Fi 동글이 꽂혀 있습니다.'
                echo '- 동글형은 설치 직전에 Wi-Fi를 잠깐 켜서 내장 Wi-Fi를 한 번 더 확인하고, 있으면 설치를 멈추고 기본형을 안내합니다.';;
            *) echo '- 내장 Wi-Fi를 지금은 확인하지 못했고(꺼져 있거나 없음) 지원 동글도 꽂혀 있지 않습니다.'
               echo '- 기본형을 설치하세요. 설치기가 Wi-Fi를 잠깐 켜서 다시 확인하고, 내장 Wi-Fi가 없으면 무선만 빼고 설치한 뒤 결과 화면에서 동글형을 안내합니다.'
               echo '- 내장 Wi-Fi가 없는 차라는 걸 이미 안다면 지원 동글(AR9271/AR7010)을 꽂고 이 점검을 다시 실행하세요.';;
        esac
        echo "- 무선: $WL"
        echo '- 무선 연결 때 차 일반 핫스팟 이름·암호가 CarPlay용 값으로 바뀝니다.'
        echo '- 유선(케이블) CarPlay·Android Auto만 쓸 거라면 Wi-Fi·동글과 관계없이 기본형 `gen5w-kr-standard.zip`을 쓰세요. 무선 설정은 순정으로 두고 유선 기능만 설치하려면 USB 맨 바깥 `GEN5W-ACTION` 파일 첫 줄에 `wired-only`라고 적고 실행합니다.'
    fi
    if [ -n "$WARN" ]; then
        echo
        echo '## 확인할 점'
        echo "$WARN"
    fi
    echo
    echo '## 파일 상태'
    echo
    echo "| 파일 | 상태 |"
    echo "|---|---|"
    echo "| services.odex (시스템 핵심, 순정 유지) | $S_HOTSPOT |"
    echo "| SystemUI.odex (시동 동의 화면) | $S_SYSUI |"
    echo "| libCarPlayAudio.so (무선 오디오) | $S_AUDIO |"
    echo "| Iap2ServerApp.odex | $S_IAP2 |"
    echo "| HKMC_DiPO.odex | $S_DIPO |"
    echo "| HKMC_GPM.odex | $S_GPM |"
    echo
    echo '이 점검은 차량에 파일을 쓰지 않았습니다. 내장 Wi-Fi 확인을 위해 꺼져 있던 Wi-Fi를 최대 8초 켰다가 다시 껐을 수 있습니다(CHECK.txt의 wifi_probe). 세부 값은 CHECK.txt에 있습니다.'
} > "$OUT/CHECK.md"
sync
am broadcast -a com.hkmc.intent.action.TOAST \
    -e com.hkmc.intent.extra.TOAST_MESSAGE "점검 완료: USB의 GEN5W-REPORT/CHECK.md에서 받을 버전을 확인하세요" \
    --ez com.hkmc.intent.extra.TOAST_POPUPSHOWING true >/dev/null 2>&1
[ -z "$BLOCK" ]
