#!/bin/bash
# Mock harness for the post-install / post-recovery cold-boot command path
# (common.sh cold_reboot, bootguard-recover.sh tail). The production code keeps
# its literal /system/bin paths; this test runs a copy with those paths pointed
# at stubs and checks which reboot commands are issued, in which order.
# This proves the shell logic only. Whether the head unit's d_audio/reboot
# actually perform a full cold boot stays VEHICLE-UNVERIFIED.
cd "$(dirname "$0")/.."
SH=${MOCK_SH:-mksh}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
pass=0; fail=0
check() { local name=$1; shift; if "$@"; then pass=$((pass+1)); else echo "FAIL $name"; fail=$((fail+1)); fi; }

B=$W/bin; LOG=$W/calls
mkdir -p "$B"
# d_audio: present unless $W/no-daudio; fails if $W/daudio-fail.
# reboot: "force_normal" fails if $W/force-fail; a real reboot never returns,
# so each stub exits the whole script after a successful call.
stubs() {
    rm -f "$B/d_audio" "$B/reboot"
    if [ ! -e "$W/no-daudio" ]; then
        cat > "$B/d_audio" <<EOF
#!/bin/sh
echo d_audio "\$@" >> "$LOG"
[ -e "$W/daudio-fail" ] && exit 1
kill -TERM \$PPID
exit 0
EOF
        chmod 755 "$B/d_audio"
    fi
    cat > "$B/reboot" <<EOF
#!/bin/sh
echo reboot "\$@" >> "$LOG"
[ "\$1" = force_normal ] && [ -e "$W/force-fail" ] && exit 1
kill -TERM \$PPID
exit 0
EOF
    chmod 755 "$B/reboot"
}

# cold_reboot() copied out of common.sh with /system/bin redirected.
sed -n '/^cold_reboot() {/,/^}/p' tools/integrated/common.sh | sed "s#/system/bin/#$B/#g" > "$W/cold.fn"
check 'cold_reboot extracted' grep -q 'force_normal' "$W/cold.fn"
check 'cold_reboot has no leftover /system/bin path' eval '! grep -q /system/bin/ "$W/cold.fn"'
cat > "$W/cold.sh" <<EOF
progress() { :; }
sync() { :; }
. "$W/cold.fn"
cold_reboot
echo returned >> "$LOG"
EOF
cold() { rm -f "$LOG"; touch "$LOG"; stubs; env ${1:+IT_NO_REBOOT=$1} "$SH" "$W/cold.sh" >/dev/null 2>&1; true; }

cold
check 'd_audio force_normal is tried first' test "$(sed -n 1p "$LOG")" = 'd_audio -c reboot force_normal'
check 'successful d_audio is the only reboot command' test "$(wc -l < "$LOG")" = 1

touch "$W/no-daudio"; cold
check 'without d_audio, reboot force_normal is used' test "$(cat "$LOG")" = 'reboot force_normal'
rm -f "$W/no-daudio"

touch "$W/daudio-fail"; cold
check 'failed d_audio falls back to reboot force_normal' test "$(sed -n 2p "$LOG")" = 'reboot force_normal'
check 'fallback stops after reboot force_normal' test "$(wc -l < "$LOG")" = 2

touch "$W/force-fail"; cold
check 'rejected force_normal falls back to a plain reboot' test "$(sed -n 3p "$LOG")" = 'reboot'
rm -f "$W/daudio-fail" "$W/force-fail"

cold 1
check 'IT_NO_REBOOT issues no reboot command' test "$(cat "$LOG")" = returned

# bootguard-recover.sh tail: only a successful restore cold-boots.
R=packages/wireless-bridge/scripts/bootguard-recover.sh
sed -n '/^# Tests stop here/,$p' "$R" | grep -v 'BG_TEST_SYS' | sed "s#/system/bin/#$B/#g" > "$W/tail.fn"
check 'recovery tail extracted' grep -q 'force_normal' "$W/tail.fn"
check 'recovery tail has no leftover /system/bin path' eval '! grep -q /system/bin/ "$W/tail.fn"'
tail_run() { rm -f "$LOG"; touch "$LOG"; stubs; printf 'sync() { :; }\nrc=%s\n' "$1" > "$W/tail.sh"; cat "$W/tail.fn" >> "$W/tail.sh"; "$SH" "$W/tail.sh" >/dev/null 2>&1; true; }

tail_run 0
check 'recovery cold-boots through d_audio first' test "$(sed -n 1p "$LOG")" = 'd_audio -c reboot force_normal'
touch "$W/no-daudio"; tail_run 0
check 'recovery without d_audio uses reboot force_normal' test "$(sed -n 1p "$LOG")" = 'reboot force_normal'
rm -f "$W/no-daudio"
tail_run 1
check 'failed recovery does not reboot' test ! -s "$LOG"
check 'production recovery still exits before reboot under tests' grep -q '^\[ -n "\$BG_TEST_SYS" \] && exit' "$R"

echo "== reboot-path: $pass passed, $fail failed"
[ "$fail" = 0 ]
