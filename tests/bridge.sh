#!/bin/bash
set -u
cd "$(dirname "$0")/.."
. tests/lib.sh
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/pkg/scripts" "$W/pkg/bin" "$W/pkg/app" "$W/sys/app" "$W/sys/framework" "$W/data" "$W/bin" "$W/fixture"
cp packages/wireless-bridge/scripts/*.sh "$W/pkg/scripts/" 2>/dev/null || true
printf 'stock035\n' > "$W/fixture/v035-original"; printf 'patched035\n' > "$W/fixture/v035-patched"
printf 'stock039\n' > "$W/fixture/v039-original"; printf 'patched039\n' > "$W/fixture/v039-patched"
printf 'legacy035\n' > "$W/fixture/v035-legacy"
printf 'legacy039\n' > "$W/fixture/v039-legacy"
printf 'stockgl3\n' > "$W/fixture/v039gl3-original"; printf 'patchedgl3\n' > "$W/fixture/v039gl3-patched"
printf 'legacygl3\n' > "$W/fixture/v039gl3-legacy"; printf 'apkgl3\n' > "$W/fixture/v039gl3-apk"
printf 'apk035\n' > "$W/fixture/v035-apk"; printf 'apk039\n' > "$W/fixture/v039-apk"
for version in v035 v039 v039gl3; do
    echo "dipo-$version-original" > "$W/fixture/dipo-$version-original"
    echo "dipo-$version-patched" > "$W/fixture/dipo-$version-patched"
    echo "dipo-$version-previous" > "$W/fixture/dipo-$version-previous"
    echo "dipo-$version-previous2" > "$W/fixture/dipo-$version-previous2"
    echo "dipo-$version-apk" > "$W/fixture/dipo-$version-apk"
done
for version in v035 v039 v039gl3; do
    echo "gpm-$version-original" > "$W/fixture/gpm-$version-original"
    echo "gpm-$version-patched" > "$W/fixture/gpm-$version-patched"
    echo "gpm-$version-apk" > "$W/fixture/gpm-$version-apk"
done
cat > "$W/pkg/scripts/recipe.sh" <<'EOF'
BRIDGE_APK_V035_SHA=v035-apk
BRIDGE_APK_V039_SHA=v039-apk
BRIDGE_DIPO_APK_V035_SHA=dipo-v035-apk
BRIDGE_DIPO_APK_V039_SHA=dipo-v039-apk
BRIDGE_GPM_APK_V035_SHA=gpm-v035-apk
BRIDGE_GPM_APK_V039_SHA=gpm-v039-apk
BRIDGE_APK_V039GL3_SHA=v039gl3-apk
BRIDGE_DIPO_APK_V039GL3_SHA=dipo-v039gl3-apk
BRIDGE_GPM_APK_V039GL3_SHA=gpm-v039gl3-apk
BRIDGE_DIPO_PREVIOUS_V035_SHAS="dipo-v035-previous dipo-v035-previous2"
BRIDGE_DIPO_PREVIOUS_V039_SHAS="dipo-v039-previous dipo-v039-previous2"
EOF
for version in v035 v039 v039gl3; do
cat > "$W/pkg/bin/iap2-patch-$version" <<'EOF'
#!/bin/sh
version=${0##*-}
case "$1" in
original) cmp -s "$2" "$BRIDGE_TEST_FIXTURE/$version-original";;
patched) cmp -s "$2" "$BRIDGE_TEST_FIXTURE/$version-legacy";;
verify) cmp -s "$2" "$BRIDGE_TEST_FIXTURE/$3";;
apply) cmp -s "$2" "$BRIDGE_TEST_FIXTURE/$version-original" && cp "$BRIDGE_TEST_FIXTURE/$version-legacy" "$3";;
*) exit 2;;
esac
EOF
cat > "$W/pkg/bin/iap2-route-patch-$version" <<'EOF'
#!/bin/sh
version=${0##*-}
case "$1" in
original) cmp -s "$2" "$BRIDGE_TEST_FIXTURE/$version-original";;
patched) cmp -s "$2" "$BRIDGE_TEST_FIXTURE/$version-patched";;
verify) cmp -s "$2" "$BRIDGE_TEST_FIXTURE/$3";;
apply) cmp -s "$2" "$BRIDGE_TEST_FIXTURE/$version-original" && cp "$BRIDGE_TEST_FIXTURE/$version-patched" "$3";;
*) exit 2;;
esac
EOF
done
for version in v035 v039 v039gl3; do
cat > "$W/pkg/bin/dipo-patch-$version" <<'EOF'
#!/bin/sh
version=${0##*-}
case "$1" in
original|patched) cmp -s "$2" "$BRIDGE_TEST_FIXTURE/dipo-$version-$1";;
verify) cmp -s "$2" "$BRIDGE_TEST_FIXTURE/$3";;
apply) cmp -s "$2" "$BRIDGE_TEST_FIXTURE/dipo-$version-original" && cp "$BRIDGE_TEST_FIXTURE/dipo-$version-patched" "$3";;
*) exit 2;;
esac
EOF
done
for version in v035 v039 v039gl3; do
cat > "$W/pkg/bin/gpm-patch-$version" <<'EOF'
#!/bin/sh
version=${0##*-}
case "$1" in
original|patched) cmp -s "$2" "$BRIDGE_TEST_FIXTURE/gpm-$version-$1";;
verify) cmp -s "$2" "$BRIDGE_TEST_FIXTURE/$3";;
apply) cmp -s "$2" "$BRIDGE_TEST_FIXTURE/gpm-$version-original" && cp "$BRIDGE_TEST_FIXTURE/gpm-$version-patched" "$3";;
*) exit 2;;
esac
EOF
done
cat > "$W/bin/nemesis" <<'EOF'
#!/bin/sh
echo "$*" >> "$BRIDGE_TEST_FIXTURE/calls"
if [ "$1" = root ] && [ "${BRIDGE_TEST_HOLD_BROKER:-0}" = 1 ]; then
    echo "$$" > "$BRIDGE_TEST_FIXTURE/broker-pid"
    exec sleep 30
fi
[ "$2" != "${BRIDGE_TEST_REMOUNT_FAIL:-never}" ]
EOF
cat > "$W/bin/mv" <<'EOF'
#!/bin/sh
case "$2" in
*Iap2ServerApp.odex)
if [ -f "$BRIDGE_TEST_FIXTURE/fail-mv" ]; then rm "$BRIDGE_TEST_FIXTURE/fail-mv"; exit 1; fi;;
*HKMC_DiPO.odex)
if [ -f "$BRIDGE_TEST_FIXTURE/fail-dipo-mv" ]; then rm "$BRIDGE_TEST_FIXTURE/fail-dipo-mv"; exit 1; fi;;
esac
exec /bin/mv "$@"
EOF
cat > "$W/bin/getprop" <<'EOF'
#!/bin/sh
echo 1
EOF
cat > "$W/bin/am" <<'EOF'
#!/bin/sh
echo "am $*" >> "$BRIDGE_TEST_FIXTURE/calls"
# Let the background broker stub record its invocation before the supervisor exits.
sleep 0.1
EOF
chmod +x "$W/bin/"*
# Deliberately leave extracted native helpers 0644; lifecycle must make them executable.
chmod 644 "$W/pkg/bin/"*
export PATH="$W/bin:$PATH" BRIDGE_TEST_SYS="$W/sys" BRIDGE_TEST_DATA="$W/data"
export BRIDGE_TEST_NEM="$W/bin/nemesis" BRIDGE_TEST_FIXTURE="$W/fixture"
TARGET=$W/sys/app/Iap2ServerApp.odex; APK=$W/sys/app/Iap2ServerApp.apk
DIPO=$W/sys/app/HKMC_DiPO.odex; DIPOAPK=$W/sys/app/HKMC_DiPO.apk
GPM=$W/sys/app/HKMC_GPM.odex; GPMAPK=$W/sys/app/HKMC_GPM.apk
PERSIST=$W/sys/etc/gen5w-kr-backup/bridge; MARK=$W/data/nemesis/backup/gen5w.kr.bridge
run() { mksh "$W/pkg/scripts/$1.sh" >"$W/last-run" 2>&1; rc=$?; if [ "$rc" != 0 ] && [ -n "${BRIDGE_TEST_VERBOSE:-}" ]; then cat "$W/last-run"; fi; return "$rc"; }
cp "$W/fixture/v035-original" "$TARGET"; cp "$W/fixture/v035-apk" "$APK"
cp "$W/fixture/dipo-v035-original" "$DIPO"; cp "$W/fixture/dipo-v035-apk" "$DIPOAPK"
if run pre; then bad 'missing daemon payload refused'; else ok 'missing daemon payload refused'; fi
touch "$W/pkg/app/bridge.dex"
if run pre; then bad 'missing host APK refused'; else ok 'missing host APK refused'; fi
touch "$W/pkg/app/wireless-host.apk"
for version in v035 v039 v039gl3; do
cp "$W/fixture/$version-original" "$TARGET"; cp "$W/fixture/$version-apk" "$APK"
cp "$W/fixture/dipo-$version-original" "$DIPO"; cp "$W/fixture/dipo-$version-apk" "$DIPOAPK"
if [ -f "$W/pkg/bin/gpm-patch-$version" ]; then
    cp "$W/fixture/gpm-$version-original" "$GPM"; cp "$W/fixture/gpm-$version-apk" "$GPMAPK"
fi
chmod 600 "$DIPO"
chmod 640 "$TARGET"
check "$version pre accepts exact pair" run pre
check "$version route helper made executable" test -x "$W/pkg/bin/iap2-route-patch-$version"
check "$version install" run post
check "$version iAP2 route-only capability applied" cmp -s "$TARGET" "$W/fixture/$version-patched"
check "$version DiPO patched exact" cmp -s "$DIPO" "$W/fixture/dipo-$version-patched"
if [ -f "$W/pkg/bin/gpm-patch-$version" ]; then
    check "$version GPM patched exact" cmp -s "$GPM" "$W/fixture/gpm-$version-patched"
    check "$version durable GPM original" cmp -s "$PERSIST/gpmoriginal" "$W/fixture/gpm-$version-original"
fi
check "$version DiPO metadata preserved" test "$(stat -c %a "$DIPO")" = 600
check "$version metadata preserved" test "$(stat -c %a "$TARGET")" = 640
check "$version durable original" cmp -s "$PERSIST/original" "$W/fixture/$version-original"
check "$version owner records its profile" test "$(cat "$PERSIST/owner")" = "gen5w.kr.bridge:$version-1"
check "$version durable DiPO original" cmp -s "$PERSIST/dipooriginal" "$W/fixture/dipo-$version-original"
check "$version reinstall" run post
rm -rf "$MARK"
check "$version reset recovery" run post
check "$version runtime original restored" cmp -s "$MARK/original" "$W/fixture/$version-original"
echo foreign > "$TARGET"
if run preun; then bad "$version foreign target refused"; else ok "$version foreign target refused"; fi
cp "$W/fixture/$version-patched" "$TARGET"
check "$version uninstall" run preun
check "$version second preuninstall after removal succeeds (NEMESIS 1.16)" run preun
check "$version original identity" cmp -s "$TARGET" "$W/fixture/$version-original"
check "$version DiPO original identity" cmp -s "$DIPO" "$W/fixture/dipo-$version-original"
if [ -f "$W/pkg/bin/gpm-patch-$version" ]; then
    check "$version GPM original identity" cmp -s "$GPM" "$W/fixture/gpm-$version-original"
fi
check "$version DiPO original mode" test "$(stat -c %a "$DIPO")" = 600
check "$version uninstall mode restored" test "$(stat -c %a "$TARGET")" = 640
check "$version owned state removed" test ! -d "$PERSIST"
if [ "$version" = v039 ]; then other=v035; else other=v039; fi
cp "$W/fixture/gpm-$other-original" "$GPM"
if run pre; then bad "$version mismatched GPM ODEX refused"; else ok "$version mismatched GPM ODEX refused"; fi
cp "$W/fixture/gpm-$version-original" "$GPM"
cp "$W/fixture/gpm-$other-apk" "$GPMAPK"
if run pre; then bad "$version mismatched GPM APK refused"; else ok "$version mismatched GPM APK refused"; fi
# A complete reviewed GPM pair is selected by its own hashes, not the bridge label.
cp "$W/fixture/gpm-$other-original" "$GPM"
check "$version accepts independently matched GPM pair" run pre

cp "$W/fixture/gpm-$version-original" "$GPM"
cp "$W/fixture/gpm-$version-apk" "$GPMAPK"

done
# Vehicle profiles never mix: a GL3 iAP2 ODEX with the reference vehicle's DiPO is skipped.
cp "$W/fixture/v039gl3-original" "$TARGET"; cp "$W/fixture/v039gl3-apk" "$APK"
cp "$W/fixture/dipo-v039-original" "$DIPO"; cp "$W/fixture/dipo-v039-apk" "$DIPOAPK"
run pre; rc=$?; check 'GL3 iAP2 with reference DiPO is skip77' test "$rc" = 77
check 'mixed profiles create no backup' test ! -d "$PERSIST"
cp "$W/fixture/v039-original" "$TARGET"; cp "$W/fixture/v039-apk" "$APK"
cp "$W/fixture/dipo-v039gl3-original" "$DIPO"; cp "$W/fixture/dipo-v039gl3-apk" "$DIPOAPK"
run pre; rc=$?; check 'reference iAP2 with GL3 DiPO is skip77' test "$rc" = 77
cp "$W/fixture/v039-original" "$TARGET"; cp "$W/fixture/v039-apk" "$APK"
cp "$W/fixture/dipo-v039-original" "$DIPO"; cp "$W/fixture/dipo-v039-apk" "$DIPOAPK"
echo unknown > "$TARGET"; run pre; rc=$?
check 'unknown stock is skip77' test "$rc" = 77
check 'unknown creates no backup' test ! -d "$PERSIST"
cp "$W/fixture/v039-original" "$TARGET"; cp "$W/fixture/v035-apk" "$APK"
run pre; rc=$?; check 'mismatched APK skip77' test "$rc" = 77
# Diagnostic bisection switch (GEN5W-BRIDGE-TEST written by the bundle).
TESTMARK=$W/data/nemesis/gen5wkr.bridge.test
cp "$W/fixture/v039gl3-original" "$TARGET"; cp "$W/fixture/v039gl3-apk" "$APK"
cp "$W/fixture/dipo-v039gl3-original" "$DIPO"; cp "$W/fixture/dipo-v039gl3-apk" "$DIPOAPK"
cp "$W/fixture/gpm-v039gl3-original" "$GPM"; cp "$W/fixture/gpm-v039gl3-apk" "$GPMAPK"
echo skip-iap2 > "$TESTMARK"
check 'skip-iap2 install' run post
check 'skip-iap2 keeps iAP2 stock' cmp -s "$TARGET" "$W/fixture/v039gl3-original"
check 'skip-iap2 still patches DiPO' cmp -s "$DIPO" "$W/fixture/dipo-v039gl3-patched"
check 'skip-iap2 still patches GPM' cmp -s "$GPM" "$W/fixture/gpm-v039gl3-patched"
check 'skip-iap2 keeps the iAP2 backup' cmp -s "$PERSIST/original" "$W/fixture/v039gl3-original"
check 'skip-iap2 logs the test mode' grep -q '^TEST bridge: iAP2 stock=yes, DiPO stock=no' "$W/last-run"
check 'skip-iap2 service accepts stock iAP2' env BRIDGE_TEST_ONCE=1 mksh "$W/pkg/scripts/service.sh"
check 'skip-iap2 reinstall' run post
rm -f "$TESTMARK"
if env BRIDGE_TEST_ONCE=1 mksh "$W/pkg/scripts/service.sh" >/dev/null 2>&1; then bad 'service refuses stock iAP2 without the switch'; else ok 'service refuses stock iAP2 without the switch'; fi
check 'normal install over skip-iap2 patches iAP2' run post
check 'switch removed: iAP2 patched' cmp -s "$TARGET" "$W/fixture/v039gl3-patched"
printf 'skip-iap2\nskip-dipo\n' > "$TESTMARK"
check 'skip-iap2+skip-dipo over a patched unit' run post
check 'both skipped: iAP2 restored to stock' cmp -s "$TARGET" "$W/fixture/v039gl3-original"
check 'both skipped: DiPO restored to stock' cmp -s "$DIPO" "$W/fixture/dipo-v039gl3-original"
check 'both skipped: GPM still patched' cmp -s "$GPM" "$W/fixture/gpm-v039gl3-patched"
check 'both skipped uninstall' run preun
check 'uninstall restores GPM' cmp -s "$GPM" "$W/fixture/gpm-v039gl3-original"
check 'uninstall removes the switch' test ! -e "$TESTMARK"
check 'both skipped owned state removed' test ! -d "$PERSIST"
echo skip-all > "$TESTMARK"
if run pre; then bad 'unknown switch token refused'; else ok 'unknown switch token refused'; fi
check 'unknown switch token changes nothing' cmp -s "$TARGET" "$W/fixture/v039gl3-original"
rm -f "$TESTMARK"
cp "$W/fixture/v039-original" "$TARGET"; cp "$W/fixture/v035-apk" "$APK"
cp "$W/fixture/dipo-v039-original" "$DIPO"; cp "$W/fixture/dipo-v039-apk" "$DIPOAPK"
cp "$W/fixture/gpm-v039-original" "$GPM"; cp "$W/fixture/gpm-v039-apk" "$GPMAPK"
cp "$W/fixture/v039-apk" "$APK"
touch "$W/fixture/fail-dipo-mv"
if run post; then bad 'rename failure rejected'; else ok 'rename failure rejected'; fi
check 'rename failure target stock' cmp -s "$TARGET" "$W/fixture/v039-original"
check 'interrupted install retry' run post
# Simulate an interrupted owned stage after durable originals were written.
echo incomplete > "$TARGET.gen5w-kr-bridge.tmp"
echo gen5w.kr.bridge:v039-1 > "$PERSIST/staging"
check 'interrupted owned stage recovered' run post
check 'uninstall after recovery' run preun
mkdir -p "$PERSIST"; echo foreign > "$PERSIST/owner"
if run post; then bad 'foreign ownership refused'; else ok 'foreign ownership refused'; fi
check 'foreign ownership preserved' test "$(cat "$PERSIST/owner")" = foreign
rm -rf "$PERSIST"
export BRIDGE_TEST_REMOUNT_FAIL=rw
if run post; then bad 'rw failure refused'; else ok 'rw failure refused'; fi
check 'rw failure unchanged' cmp -s "$TARGET" "$W/fixture/v039-original"
unset BRIDGE_TEST_REMOUNT_FAIL
check 'install for backup corruption test' run post
echo corrupt > "$PERSIST/original"
if run preun; then bad 'corrupt backup refuses uninstall'; else ok 'corrupt backup refuses uninstall'; fi
check 'corrupt backup target retained' cmp -s "$TARGET" "$W/fixture/v039-patched"
cp "$W/fixture/v039-original" "$PERSIST/original"
check 'cleanup corruption fixture' run preun
cp "$W/fixture/v039-original" "$TARGET"
ln -s "$W/fixture/v039-original" "$TARGET.gen5w-kr-bridge.tmp"
if run post; then bad 'symlink stage refused'; else ok 'symlink stage refused'; fi
check 'symlink target preserved' cmp -s "$W/fixture/v039-original" "$TARGET"
rm "$TARGET.gen5w-kr-bridge.tmp"
check 'retry after stage symlink removed' run post
check 'read-only remount issued' grep -q '^remount ro$' "$W/fixture/calls"
touch "$W/pkg/app/bridge.dex"
export BRIDGE_TEST_ONCE=1
rm -f "$W/data/nemesis/gen5wkr.bridge.stopping"
before=$(wc -l < "$W/fixture/calls")
check 'bridge waits without the match marker' run service
check 'no match marker launches no daemon' test "$(wc -l < "$W/fixture/calls")" = "$before"
echo match > "$W/data/nemesis/gen5wkr.ap-match"
check 'service starts the OEM request observer' run service
check 'service does not launch private AP broker' eval '! grep -q "ApBroker\|root 1000 -c" "$W/fixture/calls"'
check 'registered Android host is started' grep -q '^am startservice -n kr.gen5w.wirelesshost/kr.gen5w.wireless.BridgeHostService' "$W/fixture/calls"
check 'Android host stops with the supervisor' grep -q '^am stopservice -n kr.gen5w.wirelesshost/kr.gen5w.wireless.BridgeHostService' "$W/fixture/calls"
# NEMESIS sends SIGTERM, then SIGKILL after 200 ms. Exercise the supervisor
# while it is waiting, rather than only its normal one-shot exit.
: > "$W/fixture/calls"
BRIDGE_TEST_ONCE= BRIDGE_TEST_HOLD_BROKER=1 mksh "$W/pkg/scripts/service.sh" >/dev/null 2>&1 &
supervisor=$!
for _i in 1 2 3 4 5 6 7 8 9 10; do
    grep -q '^am startservice' "$W/fixture/calls" && break
    sleep 0.1
done
sleep 0.3
kill -TERM "$supervisor" 2>/dev/null || :
sleep 0.2
if kill -0 "$supervisor" 2>/dev/null; then
    bad 'supervisor responds promptly to SIGTERM'
    kill -KILL "$supervisor" 2>/dev/null || :
else
    ok 'supervisor responds promptly to SIGTERM'
fi
wait "$supervisor" 2>/dev/null || :
check 'SIGTERM requests Android host stop' grep -q '^am stopservice -n kr.gen5w.wirelesshost/kr.gen5w.wireless.BridgeHostService' "$W/fixture/calls"
check 'SIGTERM does not leave a privileged broker' eval '! grep -q "ApBroker\|root 1000 -c" "$W/fixture/calls"'
# No readiness marker simulates a host which repeatedly dies on startup.
: > "$W/fixture/calls"
BRIDGE_TEST_ONCE= BRIDGE_TEST_INTERVAL=0.1 BRIDGE_TEST_HOLD_BROKER=1 mksh "$W/pkg/scripts/service.sh" >/dev/null 2>&1 || :
check 'host startup failure stops after three attempts' test "$(grep -c '^am startservice' "$W/fixture/calls")" = 3
: > "$W/fixture/calls"
BRIDGE_TEST_ONCE= BRIDGE_TEST_INTERVAL=0.1 mksh "$W/pkg/scripts/service.sh" > "$W/fixture/retry.log" 2>&1 || :
check 'private AP broker retry is absent' eval '! grep -q "ApBroker\|root 1000 -c" "$W/fixture/calls"'
before=$(wc -l < "$W/fixture/calls")
touch "$W/data/nemesis/gen5wkr.noreboot"
check 'bridge waits while installation needs a reboot' run service
check 'pending reboot launches no daemon' test "$(wc -l < "$W/fixture/calls")" = "$before"
rm "$W/data/nemesis/gen5wkr.noreboot"
check 'match mode starts the bridge' run service
check 'match mode launches the daemon' test "$(wc -l < "$W/fixture/calls")" -gt "$before"
# Dongle edition: wired until the USB Wi-Fi interface exists.
printf '#!/bin/sh\n[ "$1" = persist.gen5w.wifi.backend ] && echo dongle || echo 1\n' > "$W/bin/getprop"
mkdir -p "$W/net"; export BRIDGE_TEST_NET=$W/net
before=$(wc -l < "$W/fixture/calls")
check 'dongle edition waits without wlan0' run service
check 'no dongle interface launches no daemon' test "$(wc -l < "$W/fixture/calls")" = "$before"
mkdir "$W/net/wlan0"
check 'dongle edition starts once wlan0 exists' run service
check 'dongle interface launches the daemon' test "$(wc -l < "$W/fixture/calls")" -gt "$before"
printf '#!/bin/sh\necho 1\n' > "$W/bin/getprop"; unset BRIDGE_TEST_NET
before=$(wc -l < "$W/fixture/calls")
touch "$W/data/nemesis/gen5wkr.noreboot"
check 'match mode still waits for the reboot' run service
check 'match mode pending reboot launches no daemon' test "$(wc -l < "$W/fixture/calls")" = "$before"
rm "$W/data/nemesis/gen5wkr.noreboot"
echo other > "$W/data/nemesis/gen5wkr.ap-match"
check 'wrong match marker waits' run service
check 'wrong match marker launches no daemon' test "$(wc -l < "$W/fixture/calls")" = "$before"
rm -f "$W/data/nemesis/gen5wkr.ap-match"
echo match > "$W/match-src"; ln -s "$W/match-src" "$W/data/nemesis/gen5wkr.ap-match"
check 'symlinked match marker waits' run service
check 'symlinked match marker launches no daemon' test "$(wc -l < "$W/fixture/calls")" = "$before"
rm -f "$W/data/nemesis/gen5wkr.ap-match" "$W/match-src"
# AP start guard: an attempt left from an earlier boot counts; three in a row turn wireless off.
echo match > "$W/data/nemesis/gen5wkr.ap-match"
APG=$W/data/nemesis/gen5wkr.apguard
export BRIDGE_TEST_BOOT_ID=boot-now
launches() { wc -l < "$W/fixture/calls"; }
before=$(launches)
check 'guard dir created on first run' eval 'run service && test -d "$APG" && test "$(cat "$APG.count")" = 0'
check 'clean boot launches the daemon' test "$(launches)" -gt "$before"
echo boot-now > "$APG/attempt"
check 'attempt from this boot is not counted' eval 'run service && test "$(cat "$APG.count")" = 0 && test -f "$APG/attempt"'
for n in 1 2; do
    echo boot-old > "$APG/attempt"
    check "restart during AP start counted ($n)" eval 'run service && test "$(cat "$APG.count")" = '$n' && test ! -e "$APG/attempt" && test ! -e "$APG.off"'
done
echo ok > "$APG/ok"; echo boot-old > "$APG/attempt"
check 'a later success resets the count before the new attempt' eval 'run service && test "$(cat "$APG.count")" = 1 && test ! -e "$APG/ok"'
echo 2 > "$APG.count"; echo boot-old > "$APG/attempt"
before=$(launches)
check 'third restart in a row turns wireless off' eval 'run service && test "$(cat "$APG.count")" = 3 && test -f "$APG.off"'
check 'guard off launches no daemon' test "$(launches)" = "$before"
check 'guard off stays off on later boots' eval 'run service && test "$(launches)" = "$before"'
rm -f "$APG.off"; echo 0 > "$APG.count"
ln -s "$W/elsewhere" "$APG/attempt"
check 'symlinked attempt keeps the unit wired-only' eval 'run service && test "$(launches)" = "$before"'
rm -f "$APG/attempt"
echo 2 > "$APG.count"; touch "$APG.off"
check 'reinstall clears the guard' eval 'run post && test ! -e "$APG" && test ! -e "$APG.count" && test ! -e "$APG.off"'
unset BRIDGE_TEST_BOOT_ID
rm -f "$W/data/nemesis/gen5wkr.ap-match"
before=$(launches)
touch "$W/data/nemesis/gen5wkr.wireless-disabled"
check 'wired-only supervisor stays available without wireless daemon' run service
check 'wired-only launches no Bluetooth daemon' test "$(wc -l < "$W/fixture/calls")" = "$before"
rm "$W/data/nemesis/gen5wkr.wireless-disabled"
touch "$W/data/nemesis/gen5wkr.bridge.stopping"
check 'stopping marker exits supervisor' run service
check 'stopping marker launches no daemon' test "$(wc -l < "$W/fixture/calls")" = "$before"
check 'post clears stopping marker' run post
check 'stopping marker removed on success' test ! -e "$W/data/nemesis/gen5wkr.bridge.stopping"
echo foreign > "$TARGET"
before=$(wc -l < "$W/fixture/calls")
if run service; then bad 'service refuses changed firmware'; else ok 'service refuses changed firmware'; fi
check 'changed firmware launches no daemon' test "$(wc -l < "$W/fixture/calls")" = "$before"
cp "$W/fixture/v039-patched" "$TARGET"
cp "$W/fixture/dipo-v039-original" "$DIPO"
check 'resume iAP patched DiPO original pair' run post
check 'resumed DiPO patched exact' cmp -s "$DIPO" "$W/fixture/dipo-v039-patched"
cp "$W/fixture/v039-original" "$TARGET"
check 'resume iAP original DiPO patched pair' run post
check 'resumed iAP route capability restored' cmp -s "$TARGET" "$W/fixture/v039-patched"
check 'cleanup partial pairs' run preun
touch "$W/fixture/fail-dipo-mv"
if run post; then bad 'second target failure rejected'; else ok 'second target failure rejected'; fi
check 'second failure leaves iAP stock' cmp -s "$TARGET" "$W/fixture/v039-original"
check 'second failure leaves DiPO original' cmp -s "$DIPO" "$W/fixture/dipo-v039-original"
check 'retry second target failure' run post
echo corrupt > "$PERSIST/dipooriginal"
if run preun; then bad 'corrupt DiPO backup refuses pair restore'; else ok 'corrupt DiPO backup refuses pair restore'; fi
check 'corrupt DiPO backup leaves iAP route capability intact' cmp -s "$TARGET" "$W/fixture/v039-patched"
cp "$W/fixture/dipo-v039-original" "$PERSIST/dipooriginal"
cp "$W/fixture/dipo-v035-apk" "$DIPOAPK"
if run post; then bad 'DiPO APK drift refused'; else ok 'DiPO APK drift refused'; fi
check 'DiPO APK drift leaves iAP route capability intact' cmp -s "$TARGET" "$W/fixture/v039-patched"
cp "$W/fixture/dipo-v039-apk" "$DIPOAPK"
cp "$W/fixture/dipo-v039-original" "$DIPO"
before=$(wc -l < "$W/fixture/calls")
if run service; then bad 'partial pair refuses daemon startup'; else ok 'partial pair refuses daemon startup'; fi
check 'partial pair launches no daemon' test "$(wc -l < "$W/fixture/calls")" = "$before"
check 'resume partial pair after boot refusal' run post
echo foreign > "$DIPO"
if run preun; then bad 'foreign DiPO refuses restore pair'; else ok 'foreign DiPO refuses restore pair'; fi
check 'foreign DiPO leaves iAP route capability intact' cmp -s "$TARGET" "$W/fixture/v039-patched"
cp "$W/fixture/dipo-v039-patched" "$DIPO"
check 'cleanup foreign fixture' run preun
cp "$W/fixture/dipo-v035-original" "$DIPO"; cp "$W/fixture/dipo-v035-apk" "$DIPOAPK"
run pre; rc=$?; check 'crossversion pair skipped' test "$rc" = 77
# Preserve the previously supported V039 bridge + older reviewed GPM app pair.
cp "$W/fixture/v039-original" "$TARGET"; cp "$W/fixture/v039-apk" "$APK"
cp "$W/fixture/dipo-v039-original" "$DIPO"; cp "$W/fixture/dipo-v039-apk" "$DIPOAPK"
cp "$W/fixture/gpm-v035-original" "$GPM"; cp "$W/fixture/gpm-v035-apk" "$GPMAPK"
check 'V039 bridge installs reviewed older GPM pair' run post
check 'older GPM uses its own patch' cmp -s "$GPM" "$W/fixture/gpm-v035-patched"
check 'independent GPM pair uninstall' run preun
check 'independent GPM original restored' cmp -s "$GPM" "$W/fixture/gpm-v035-original"
cp "$W/fixture/gpm-v039-original" "$GPM"; cp "$W/fixture/gpm-v039-apk" "$GPMAPK"
# Updating the legacy full control shim must remove that code and retain only
# the stock-compatible Wi-Fi/RouteGuidance feature declaration.
cp "$W/fixture/v039-legacy" "$TARGET"; cp "$W/fixture/v039-apk" "$APK"
cp "$W/fixture/dipo-v039-original" "$DIPO"; cp "$W/fixture/dipo-v039-apk" "$DIPOAPK"
mkdir -p "$PERSIST"
echo gen5w.kr.bridge:v039-1 > "$PERSIST/owner"
cp "$W/fixture/v039-original" "$PERSIST/original"
cp "$W/fixture/dipo-v039-original" "$PERSIST/dipooriginal"
check 'legacy iAP2 control shim recognized for update' run pre
check 'legacy iAP2 shim upgraded to route-only capability' run post
check 'legacy control shim absent after update' cmp -s "$TARGET" "$W/fixture/v039-patched"
check 'route-only capability removal restores exact original' eval 'run preun && cmp -s "$TARGET" "$W/fixture/v039-original"'

# Upgrade both previously shipped DiPO recipes for both supported system versions.
# Only profiles that shipped an earlier DiPO patch (GL3 never did).
for version in v035 v039; do
    for legacy in previous previous2; do
        cp "$W/fixture/$version-original" "$TARGET"; cp "$W/fixture/$version-apk" "$APK"
        cp "$W/fixture/dipo-$version-original" "$DIPO"; cp "$W/fixture/dipo-$version-apk" "$DIPOAPK"
        check "$version $legacy setup owned package" run post
        cp "$W/fixture/dipo-$version-$legacy" "$DIPO"
        check "$version $legacy accepted at preflight" run pre
        check "$version $legacy upgraded from original backup" run post
        check "$version $legacy produces current DiPO" cmp -s "$DIPO" "$W/fixture/dipo-$version-patched"
        check "$version $legacy preserves stock backup" cmp -s "$PERSIST/dipooriginal" "$W/fixture/dipo-$version-original"
        cp "$W/fixture/dipo-$version-$legacy" "$DIPO"
        check "$version $legacy direct restore" run preun
        check "$version $legacy restore is stock exact" cmp -s "$DIPO" "$W/fixture/dipo-$version-original"
        cp "$W/fixture/dipo-$version-$legacy" "$DIPO"
        if run post; then bad "$version unowned $legacy refused"; else ok "$version unowned $legacy refused"; fi
        check "$version unowned $legacy creates no backup" test ! -d "$PERSIST"
    done
done

# Firmware reinstall: stock ODEX files and no system journal, but our runtime
# copies and start-guard state still in /data.
reinstall_system() {
    cp "$W/fixture/v039-original" "$TARGET"; cp "$W/fixture/dipo-v039-original" "$DIPO"
    [ ! -f "$W/pkg/bin/gpm-patch-v039" ] || cp "$W/fixture/gpm-v039-original" "$GPM"
    rm -rf "$PERSIST"
}
cp "$W/fixture/v039-original" "$TARGET"; cp "$W/fixture/v039-apk" "$APK"
cp "$W/fixture/dipo-v039-original" "$DIPO"; cp "$W/fixture/dipo-v039-apk" "$DIPOAPK"
check 'install before system reinstall' run post
reinstall_system; mkdir -p "$W/data/nemesis/gen5wkr.apguard"; echo 2 > "$W/data/nemesis/gen5wkr.apguard.count"
check 'removal after system reinstall' run preun
check 'removal clears runtime copies' test ! -e "$MARK"
check 'removal clears the start guard' eval 'test ! -e "$W/data/nemesis/gen5wkr.apguard" && test ! -e "$W/data/nemesis/gen5wkr.apguard.count"'
check 'removal leaves stock ODEX' cmp -s "$TARGET" "$W/fixture/v039-original"
run post; reinstall_system
check 'reinstall after system reinstall' run post
check 'reinstall restores route-only capability' cmp -s "$TARGET" "$W/fixture/v039-patched"
check 'removal after that reinstall restores stock' eval 'run preun && cmp -s "$TARGET" "$W/fixture/v039-original"'
run post; reinstall_system; echo other-firmware > "$TARGET"
check 'removal on other firmware clears our copies' run preun
check 'other firmware ODEX untouched' test "$(cat "$TARGET")" = other-firmware
check 'other firmware runtime copies cleared' test ! -e "$MARK"
cp "$W/fixture/v039-original" "$TARGET"; run post; rm -rf "$PERSIST"
if run preun; then bad 'patched ODEX without journal refused'; else ok 'patched ODEX without journal refused'; fi
check 'refusal keeps runtime copies' cmp -s "$MARK/original" "$W/fixture/v039-original"
cp "$W/fixture/v039-patched" "$TARGET"
if run pre; then bad 'route capability ODEX without journal refused'; else ok 'route capability ODEX without journal refused'; fi
check 'unowned route capability creates no system journal' test ! -e "$PERSIST"

done_tests bridge
