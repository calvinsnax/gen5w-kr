#!/bin/bash
# Read-only pre-install check: verdicts from fake verifiers, and nothing on the unit changes.
cd "$(dirname "$0")/.."
SH=${MOCK_SH:-mksh}
. tests/unit/shim.sh
unit_shim_setup || exit 1
W=$(mktemp -d); trap 'rm -rf "$W"; unit_shim_cleanup' EXIT
pass=0; fail=0
check() { local name=$1; shift; if "$@"; then pass=$((pass+1)); else echo "FAIL $name"; fail=$((fail+1)); fi; }

U=$W/usb; S=$W/sys; D=$W/data; B=$W/stub; F=$W/sysfs
mkdir -p "$U" "$S/framework" "$S/priv-app" "$S/lib" "$S/app" "$S/etc/permissions" "$D/nemesis/apps" "$B"
cp tools/integrated/check.sh "$U/"
echo 0123456789abcdef > "$U/BUILD-REVISION"
tool() { # checks/<id>/bin/<name>: original if first line "stock", patched if "patched"
    mkdir -p "$U/checks/$1/bin"
    cat > "$U/checks/$1/bin/$2" <<'EOF'
#!/bin/sh
case "$1" in original) grep -q '^stock' "$2";; patched) grep -q '^patched' "$2";; *) exit 2;; esac
EOF
    chmod 755 "$U/checks/$1/bin/$2"
}
# SHA-256 checker for the two boot-critical files (stock V039 hashes only).
mkdir -p "$U/checks/gen5w.kr.timer/bin"
cat > "$U/checks/gen5w.kr.timer/bin/sha256-check" <<'EOF'
#!/bin/sh
case "$1:$3" in verify:63cf*|verify:97e7*) grep -q '^stock' "$2";; verify:01f4*|verify:5d9d*) grep -q '^gl3stock' "$2";; *) exit 1;; esac
EOF
chmod 755 "$U/checks/gen5w.kr.timer/bin/sha256-check"
tool gen5w.kr.audio audio-patch
for t in iap2 dipo gpm; do tool gen5w.kr.bridge $t-patch-v039; done
cat > "$U/checks/gen5w.kr.bridge/bin/iap2-route-patch-v039" <<'EOF'
#!/bin/sh
case "$1" in original) grep -q '^stock' "$2";; patched) grep -q '^route-capability' "$2";; *) exit 2;; esac
EOF
chmod 755 "$U/checks/gen5w.kr.bridge/bin/iap2-route-patch-v039"
cat > "$U/checks/gen5w.kr.bridge/bin/iap2-patch-v039" <<'EOF'
#!/bin/sh
case "$1" in original) grep -q '^stock' "$2";; patched) grep -q '^legacy-control' "$2";; *) exit 2;; esac
EOF
chmod 755 "$U/checks/gen5w.kr.bridge/bin/iap2-patch-v039"
# K8 GL3 HEV profile: its own verifiers recognise only "gl3stock"/"gl3patched".
gl3tool() {
    mkdir -p "$U/checks/$1/bin"
    printf '#!/bin/sh\ncase "$1" in original) grep -q "^gl3stock" "$2";; patched) grep -q "^gl3patched" "$2";; *) exit 2;; esac\n' > "$U/checks/$1/bin/$2"
    chmod 755 "$U/checks/$1/bin/$2"
}
gl3tool gen5w.kr.audio audio-patch-v039gl3
for t in iap2 iap2-route dipo gpm; do gl3tool gen5w.kr.bridge $t-patch-v039gl3; done
cat > "$B/getprop" <<'EOF'
#!/bin/sh
case "$1" in ro.build.product) echo OSHEV.KOR;; ro.build.display.id) echo V039.001.260902;; *) echo;; esac
EOF
printf '#!/bin/sh\necho 0\n' > "$B/settings"
printf '#!/bin/sh\necho "$*" >> "$CK_TEST_AM_LOG"\nexit 0\n' > "$B/am"
printf '#!/bin/sh\nexit 0\n' > "$B/dmesg"
chmod 755 "$B"/*
stock() {
    for f in framework/services.odex priv-app/SystemUI.odex lib/libCarPlayAudio.so app/Iap2ServerApp.odex app/HKMC_GPM.odex; do echo stock > "$S/$f"; done
    printf 'stock\ncarplay_wireless\n' > "$S/app/HKMC_DiPO.odex"
}
run() {
    rm -rf "$U/GEN5W-REPORT"
    : > "$W/am.log"
    (cd "$U" && IT_DATA=$D IT_SYSTEM=$S CK_TEST_SYSFS=$F CK_TEST_AM="$B/am" CK_TEST_AM_LOG="$W/am.log" CK_TEST_PATH="$B:$GEN5W_UNIT_SHIM/bin:/usr/bin:/bin" "$SH" ./check.sh) >/dev/null 2>&1
}
snapshot() { (cd "$W" && find sys data -type f -exec md5sum {} + | sort); }

stock
touch "$U/GEN5W-CHECK-ONLY"
check 'check edition runs with progress' run
for step in 1 2 3 4 5; do
    check "check edition shows step $step" grep -q "점검 ($step/5)" "$W/am.log"
done
check 'check edition announces completion' grep -q '점검 완료' "$W/am.log"
: > "$W/am.log"
check 'internal verification still succeeds' bash -c 'cd "$1" && IT_DATA="$2" IT_SYSTEM="$3" CK_TEST_SYSFS="$4" CK_TEST_AM="$5/am" CK_TEST_AM_LOG="$6" CK_TEST_PATH="$5:$7/bin:/usr/bin:/bin" "$8" ./check.sh --verify >/dev/null 2>&1' _ "$U" "$D" "$S" "$F" "$B" "$W/am.log" "$GEN5W_UNIT_SHIM" "$SH"
check 'internal verification shows no progress' test ! -s "$W/am.log"
rm "$U/GEN5W-CHECK-ONLY"
check 'ordinary check runs without check-only marker' run
check 'no step progress outside check edition' eval '! grep -q "점검 (.*\/5)" "$W/am.log"'
before=$(snapshot)
check 'stock V039 passes' run
check 'verdict says install' grep -q '판정: 설치 가능' "$U/GEN5W-REPORT/CHECK.md"
check 'no unreleased edition is recommended' eval '! grep -q safe-wireless "$U/GEN5W-REPORT/CHECK.md"'
check 'unknown Wi-Fi recommends the standard edition' grep -q '받을 파일: 기본형 `gen5w-kr-standard.zip`' "$U/GEN5W-REPORT/CHECK.md"
check 'unknown Wi-Fi explains the installer re-check' grep -q '무선만 빼고 설치한 뒤 결과 화면에서 동글형을 안내' "$U/GEN5W-REPORT/CHECK.md"
check 'records the recommendation' grep -qx 'recommend=standard' "$U/GEN5W-REPORT/CHECK.txt"
check 'wired-only users are pointed to the standard edition' grep -q '유선(케이블) CarPlay·Android Auto만 쓸 거라면.*기본형' "$U/GEN5W-REPORT/CHECK.md"
check 'wired-only action is explained' grep -q '`wired-only`라고 적고' "$U/GEN5W-REPORT/CHECK.md"
mkdir -p "$F/bus/usb/devices/1-1"; echo 0cf3 > "$F/bus/usb/devices/1-1/idVendor"; echo 9271 > "$F/bus/usb/devices/1-1/idProduct"
run
check 'dongle without built-in Wi-Fi recommends the dongle edition' grep -q '받을 파일: 동글형 `gen5w-kr-dongle.zip`' "$U/GEN5W-REPORT/CHECK.md"
check 'records the dongle' grep -qx 'dongle_seen=yes' "$U/GEN5W-REPORT/CHECK.txt"
mkdir -p "$F/class/net/wlan0"
run
check 'built-in Wi-Fi recommends the standard edition even with a dongle' grep -qx 'recommend=standard' "$U/GEN5W-REPORT/CHECK.txt"
check 'built-in Wi-Fi is explained' grep -q '내장 Wi-Fi가 확인됐습니다' "$U/GEN5W-REPORT/CHECK.md"
mkdir -p "$D/nemesis/apps/gen5w.kr.dongle"; echo 'id=gen5w.kr.dongle' > "$D/nemesis/apps/gen5w.kr.dongle/NEMESIS.data"
run
check 'installed dongle edition keeps the dongle recommendation' grep -qx 'recommend=dongle' "$U/GEN5W-REPORT/CHECK.txt"
rm -rf "$F" "$D/nemesis/apps/gen5w.kr.dongle"
run
check 'records SystemUI stock' grep -qx 'systemui_odex=stock-v039' "$U/GEN5W-REPORT/CHECK.txt"
check 'records services stock' grep -qx 'services_odex=stock-v039' "$U/GEN5W-REPORT/CHECK.txt"
check 'records firmware' grep -qx 'firmware=OSHEV.KOR' "$U/GEN5W-REPORT/CHECK.txt"
check 'NEMESIS without a version command is unknown' grep -qx 'nemesis_version=unknown' "$U/GEN5W-REPORT/CHECK.txt"
mkdir -p "$S/xbin"; printf '#!/bin/sh
[ "$1" = version ] && echo 1.16.3
' > "$S/xbin/nemesis"; chmod 755 "$S/xbin/nemesis"
run
check 'records the NEMESIS version' grep -qx 'nemesis_version=1.16.3' "$U/GEN5W-REPORT/CHECK.txt"
check 'shows the NEMESIS version' grep -q -- '- NEMESIS 버전: 1.16.3' "$U/GEN5W-REPORT/CHECK.md"
rm -rf "$S/xbin"; run
check 'wireless code found' grep -qx 'wireless_code=yes' "$U/GEN5W-REPORT/CHECK.txt"
check 'nothing on the unit changed' test "$before" = "$(snapshot)"

stock; echo route-capability > "$S/app/Iap2ServerApp.odex"; run
check 'check classifies current route-only iAP2 capability' grep -qx 'iap2_odex=route-capability-v039' "$U/GEN5W-REPORT/CHECK.txt"
check 'unowned route-only capability is refused' grep -q 'RouteGuidance 기능 선언이 바뀌어 있는데 순정 백업이 없습니다' "$U/GEN5W-REPORT/CHECK.md"
mkdir -p "$S/etc/gen5w-kr-backup/bridge"; run
check 'owned route-only capability is recognized for update' grep -qx 'verdict=install' "$U/GEN5W-REPORT/CHECK.txt"
rm -rf "$S/etc/gen5w-kr-backup"
stock; echo legacy-control > "$S/app/Iap2ServerApp.odex"; run
check 'check distinguishes legacy service-control shim' grep -qx 'iap2_odex=legacy-control-v039' "$U/GEN5W-REPORT/CHECK.txt"
check 'unowned legacy service-control shim is refused' grep -q '이전 무선 제어 수정이 있지만 순정 백업이 없습니다' "$U/GEN5W-REPORT/CHECK.md"

echo junk > "$S/priv-app/SystemUI.odex"
check 'unknown SystemUI fails' eval '! run'
check 'unknown SystemUI says do not install' grep -q '판정: 설치하지 마세요' "$U/GEN5W-REPORT/CHECK.md"
check 'unknown SystemUI reason' grep -q 'SystemUI' "$U/GEN5W-REPORT/CHECK.md"

stock; echo patched > "$S/priv-app/SystemUI.odex"
check 'changed SystemUI fails' eval '! run'

stock; echo junk > "$S/app/HKMC_GPM.odex"
check 'unknown bridge target fails' eval '! run'
check 'bridge reason names file' grep -q 'HKMC_GPM' "$U/GEN5W-REPORT/CHECK.md"

stock; echo junk > "$S/framework/services.odex"
check 'unknown services.odex blocks' eval '! run'
check 'services.odex reason' grep -q 'services.odex' "$U/GEN5W-REPORT/CHECK.md"
stock; echo patched > "$S/framework/services.odex"
check 'changed services.odex blocks' eval '! run'

# A different vehicle's build (e.g. GL3HEV on the same V039.001.260902 string):
# every target is unknown. Report a new port, not "re-flash the official update".
for f in framework/services.odex priv-app/SystemUI.odex lib/libCarPlayAudio.so app/Iap2ServerApp.odex app/HKMC_GPM.odex; do echo other-vehicle > "$S/$f"; done
printf 'other-vehicle\ncarplay_wireless\n' > "$S/app/HKMC_DiPO.odex"
check 'unregistered build blocks' eval '! run'
check 'unregistered build is recorded' grep -qx 'unregistered_build=yes' "$U/GEN5W-REPORT/CHECK.txt"
check 'unregistered build says new port' grep -q '새 포트로 보이며' "$U/GEN5W-REPORT/CHECK.md"
check 'unregistered build does not ask for a re-flash' eval '! grep -q "순정 복구 후 다시 점검" "$U/GEN5W-REPORT/CHECK.md"'
check 'unregistered build keeps per-file hashes' grep -q '^md5:app/HKMC_GPM.odex=' "$U/GEN5W-REPORT/CHECK.txt"
stock; echo junk > "$S/app/HKMC_GPM.odex"; run
check 'single unknown file is not an unregistered build' grep -qx 'unregistered_build=no' "$U/GEN5W-REPORT/CHECK.txt"

# K8 GL3 HEV V039: every target matches only the GL3 profile.
gl3() {
    for f in framework/services.odex priv-app/SystemUI.odex lib/libCarPlayAudio.so app/Iap2ServerApp.odex app/HKMC_GPM.odex; do echo gl3stock > "$S/$f"; done
    printf 'gl3stock\ncarplay_wireless\n' > "$S/app/HKMC_DiPO.odex"
}
gl3
check 'GL3 stock passes' run
check 'GL3 verdict says install' grep -q '판정: 설치 가능' "$U/GEN5W-REPORT/CHECK.md"
check 'GL3 is not an unregistered build' grep -qx 'unregistered_build=no' "$U/GEN5W-REPORT/CHECK.txt"
for fact in services_odex systemui_odex carplay_audio_so iap2_odex dipo_odex gpm_odex; do
    check "GL3 $fact is stock V039" grep -qx "$fact=stock-v039" "$U/GEN5W-REPORT/CHECK.txt"
done
check 'GL3 audio is not warned about' eval '! grep -q "libCarPlayAudio.so를 확인하지 못했습니다" "$U/GEN5W-REPORT/CHECK.md"'
gl3; echo gl3patched > "$S/app/HKMC_GPM.odex"; run
check 'GL3 patched GPM without backup is refused' eval 'grep -qx "gpm_odex=patched-v039" "$U/GEN5W-REPORT/CHECK.txt" && grep -q "HKMC_GPM 파일이 이미 바뀌어" "$U/GEN5W-REPORT/CHECK.md"'
gl3; echo gl3patched > "$S/priv-app/SystemUI.odex"
check 'GL3 changed SystemUI blocks' eval '! run'
stock

stock; echo stock > "$S/app/HKMC_DiPO.odex"
check 'no wireless code still installable' run
check 'no wireless code means wired-only' grep -q '유선 전용' "$U/GEN5W-REPORT/CHECK.md"

stock; mkdir -p "$D/nemesis/apps/wireless.carplay.aa"
check 'other package passes with warning' run
check 'other package listed' grep -q 'wireless.carplay.aa' "$U/GEN5W-REPORT/CHECK.md"
rm -rf "$D/nemesis/apps/wireless.carplay.aa"

for clash in wireless.projection local.hkmc.factory82; do
    stock; mkdir -p "$D/nemesis/apps/$clash"
    check "store package $clash blocks install" eval '! run && grep -q "스토어 패키지" "$U/GEN5W-REPORT/CHECK.md" && grep -qx "store_conflicts='"$clash"'" "$U/GEN5W-REPORT/CHECK.txt"'
    rm -rf "$D/nemesis/apps/$clash"
done

stock; echo off > "$D/nemesis/gen5wkr.apguard.off"
check 'AP guard off still installable' run
check 'AP guard off recorded' grep -qx 'apguard_off=yes' "$U/GEN5W-REPORT/CHECK.txt"
check 'AP guard off warned' grep -q '무선이 자동으로 꺼져' "$U/GEN5W-REPORT/CHECK.md"
rm -f "$D/nemesis/gen5wkr.apguard.off"

mkdir -p "$D/nemesis/gen5wkr.bootguard"; : > "$D/nemesis/gen5wkr.bootguard/recovery-required"
check 'recovery-required fails' eval '! run'
rm -rf "$D/nemesis/gen5wkr.bootguard"

mkdir -p "$D/nemesis/gen5w-kr-integrated"; echo applying > "$D/nemesis/gen5w-kr-integrated/state"
check 'incomplete interrupted transaction blocks' eval '! run && grep -q "state=applying" "$U/GEN5W-REPORT/CHECK.md"'
mkdir -p "$D/nemesis/gen5w-kr-integrated/prior"; : > "$D/nemesis/gen5w-kr-integrated/prior/complete"
check 'interrupted transaction warns' eval 'run && grep -q "state=applying" "$U/GEN5W-REPORT/CHECK.md"'
rm -rf "$D/nemesis/gen5w-kr-integrated/prior"
echo recovery-required > "$D/nemesis/gen5w-kr-integrated/state"
check 'transaction recovery-required blocks install' eval '! run && grep -q "state=recovery-required" "$U/GEN5W-REPORT/CHECK.md"'
echo future-state > "$D/nemesis/gen5w-kr-integrated/state"
check 'unknown transaction state blocks install' eval '! run && grep -q "state=future-state" "$U/GEN5W-REPORT/CHECK.md" && grep -q "복구 자료를 보존" "$U/GEN5W-REPORT/CHECK.md"'
rm -f "$D/nemesis/gen5w-kr-integrated/state"

ln -s "$W/elsewhere" "$U/GEN5W-REPORT.tmp" 2>/dev/null; rm -rf "$U/GEN5W-REPORT"; ln -s "$W" "$U/GEN5W-REPORT"
check 'symlinked report dir refused' eval '! (cd "$U" && IT_DATA=$D IT_SYSTEM=$S CK_TEST_SYSFS=$F CK_TEST_PATH="$B:$GEN5W_UNIT_SHIM/bin:/usr/bin:/bin" "$SH" ./check.sh) >/dev/null 2>&1'
rm -f "$U/GEN5W-REPORT" "$U/GEN5W-REPORT.tmp"

# Built-in Wi-Fi is only visible while on: the check turns it on briefly and off again.
cat > "$B/svc" <<EOF
#!/bin/sh
echo "\$*" >> "$W/svc.log"
case "\$2" in
    enable) [ -f "$W/has_wifi" ] && mkdir -p "$F/class/net/wlan0"; [ -f "$W/stuck_on" ] && echo 1 > "$W/wifi_on";;
    disable) rm -rf "$F/class/net/wlan0";;
esac
EOF
printf '#!/bin/sh\ncat "%s/wifi_on" 2>/dev/null || echo 0\n' "$W" > "$B/settings"; chmod 755 "$B/svc" "$B/settings"
stock; touch "$W/has_wifi"; rm -f "$W/svc.log"
run
check 'probe finds built-in Wi-Fi that was off' grep -qx 'wifi_probe=found' "$U/GEN5W-REPORT/CHECK.txt"
check 'probe recommends standard for built-in Wi-Fi' grep -qx 'recommend=standard' "$U/GEN5W-REPORT/CHECK.txt"
check 'probe turns Wi-Fi off again' eval 'grep -qx "wifi enable" "$W/svc.log" && grep -qx "wifi disable" "$W/svc.log" && test ! -e "$F/class/net/wlan0"'
check 'probe result shown as Wi-Fi confirmed' grep -q '무선 조건 충족' "$U/GEN5W-REPORT/CHECK.md"
rm -f "$W/has_wifi" "$W/svc.log"; run
check 'probe without Wi-Fi reports not found' grep -qx 'wifi_probe=not-found' "$U/GEN5W-REPORT/CHECK.txt"
echo 1 > "$W/wifi_on"; rm -f "$W/svc.log"; run
check 'Wi-Fi already on is not touched' eval 'grep -qx wifi_probe=skipped "$U/GEN5W-REPORT/CHECK.txt" && test ! -e "$W/svc.log"'
rm -f "$W/wifi_on"; touch "$W/stuck_on"; run
check 'Wi-Fi that stays on is warned about' eval 'grep -qx wifi_probe=still-on "$U/GEN5W-REPORT/CHECK.txt" && grep -q "Wi-Fi를 끄세요" "$U/GEN5W-REPORT/CHECK.md"'
rm -f "$W/stuck_on" "$W/wifi_on" "$B/svc"

unit_shim_report || fail=$((fail+1))
echo "== check: $pass passed, $fail failed"
[ "$fail" = 0 ]
