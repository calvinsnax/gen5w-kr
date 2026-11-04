#!/bin/bash
# Real mksh package behavior against synthetic files only.
set -u
cd "$(dirname "$0")/.."
. tests/lib.sh
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/pkg/scripts" "$W/pkg/bin" "$W/sys/lib" "$W/data" "$W/bin" "$W/fixture"
cp packages/audio-format/scripts/*.sh "$W/pkg/scripts/" 2>/dev/null || true
cp packages/audio-format/bin/status.sh "$W/pkg/bin/status.sh"
echo stock > "$W/fixture/original"; echo patched > "$W/fixture/patched"
echo core > "$W/fixture/core"; echo utils > "$W/fixture/utils"
echo opus > "$W/fixture/opus"
echo stock35 > "$W/fixture/original35"; echo patched35 > "$W/fixture/patched35"
echo stockgl3 > "$W/fixture/originalgl3"; echo patchedgl3 > "$W/fixture/patchedgl3"
cat > "$W/pkg/scripts/recipe.sh" <<'EOF'
AUDIO_RECIPE=test-1
AUDIO_CORE_SHA=core
AUDIO_UTILS_SHA=utils
AUDIO_OPUS_SHA=opus
EOF
sed 's/test-1/test35-1/' "$W/pkg/scripts/recipe.sh" > "$W/pkg/scripts/recipe-v035.sh"
sed 's/test-1/testgl3-1/' "$W/pkg/scripts/recipe.sh" > "$W/pkg/scripts/recipe-v039gl3.sh"
cat > "$W/bin/tool" <<'EOF'
#!/bin/sh
case "$1" in
original) cmp -s "$2" "$AUDIO_TEST_FIXTURE/original";;
patched) cmp -s "$2" "$AUDIO_TEST_FIXTURE/patched";;
verify) cmp -s "$2" "$AUDIO_TEST_FIXTURE/$3";;
apply) cmp -s "$2" "$AUDIO_TEST_FIXTURE/original" && cp "$AUDIO_TEST_FIXTURE/patched" "$3";;
*) exit 2;;
esac
EOF
cat > "$W/bin/nemesis" <<'EOF'
#!/bin/sh
echo "$*" >> "$AUDIO_TEST_FIXTURE/remounts"
[ "$2" != "${AUDIO_TEST_REMOUNT_FAIL:-never}" ]
EOF
cat > "$W/bin/chown" <<'EOF'
#!/bin/sh
exit 0
EOF
sed 's@/original@/original35@g;s@/patched@/patched35@g' "$W/bin/tool" > "$W/pkg/bin/audio-patch-v035"
chmod +x "$W/pkg/bin/audio-patch-v035"
sed 's@/original@/originalgl3@g;s@/patched@/patchedgl3@g' "$W/bin/tool" > "$W/pkg/bin/audio-patch-v039gl3"
chmod 644 "$W/pkg/bin/audio-patch-v039gl3"
cat > "$W/bin/mv" <<'EOF'
#!/bin/sh
if [ -f "$AUDIO_TEST_FIXTURE/fail-mv" ] && [ "$2" = "$AUDIO_TEST_SYS/lib/libCarPlayAudio.so" ]; then
    rm "$AUDIO_TEST_FIXTURE/fail-mv"; exit 1
fi
exec /bin/mv "$@"
EOF
cat > "$W/bin/cp" <<'EOF'
#!/bin/sh
case "$*" in
*libCarPlayAudio.so.gen5w-kr-audio.tmp)
    if [ -f "$AUDIO_TEST_FIXTURE/fail-cp" ]; then
        rm "$AUDIO_TEST_FIXTURE/fail-cp"
        echo incomplete > "$AUDIO_TEST_SYS/lib/libCarPlayAudio.so.gen5w-kr-audio.tmp"
        exit 1
    fi;;
esac
exec /bin/cp "$@"
EOF
chmod +x "$W/bin/"*
export PATH="$W/bin:$PATH" AUDIO_TEST_SYS="$W/sys" AUDIO_TEST_DATA="$W/data"
export AUDIO_TEST_NEM="$W/bin/nemesis" AUDIO_TEST_TOOL="$W/bin/tool" AUDIO_TEST_FIXTURE="$W/fixture"
TARGET=$W/sys/lib/libCarPlayAudio.so
PERSIST=$W/sys/etc/gen5w-kr-backup/audio
MARK=$W/data/nemesis/backup/gen5w.kr.audio
run() { mksh "$W/pkg/scripts/$1.sh" >/dev/null 2>&1; }
cp "$W/fixture/original" "$TARGET"; cp "$W/fixture/core" "$W/sys/lib/libCarPlayCore.so"; cp "$W/fixture/utils" "$W/sys/lib/libCarPlayUtils.so"
if run pre; then bad 'audio missing Opus decoder rejected'; else ok 'audio missing Opus decoder rejected'; fi
cp "$W/fixture/opus" "$W/sys/lib/libopus.so"
check 'audio pre accepts exact stock dependencies' run pre
check 'audio status resolves script directory' mksh "$W/pkg/bin/status.sh"
echo unknown > "$TARGET"
if run post; then bad 'audio unknown state refused'; else ok 'audio unknown state refused'; fi
check 'audio mismatch creates no system backup' test ! -d "$PERSIST"
cp "$W/fixture/original" "$TARGET"
check 'audio install' run post
check 'audio installed bytes' cmp -s "$TARGET" "$W/fixture/patched"
check 'audio runtime original exact' cmp -s "$MARK/original" "$W/fixture/original"
check 'audio reset-persistent original exact' cmp -s "$PERSIST/original" "$W/fixture/original"
check 'audio reinstall' run post
check 'audio reinstall preserves original' cmp -s "$PERSIST/original" "$W/fixture/original"
rm -rf "$MARK"
check 'audio reinstall after data reset' run post
check 'audio reset runtime restored' cmp -s "$MARK/original" "$W/fixture/original"
echo foreign > "$TARGET"
if run preun; then bad 'audio foreign modification refused'; else ok 'audio foreign modification refused'; fi
cp "$W/fixture/patched" "$TARGET"
check 'audio uninstall' run preun
check 'audio second preuninstall after removal succeeds (NEMESIS 1.16)' run preun
check 'audio uninstall byte identity' cmp -s "$TARGET" "$W/fixture/original"
check 'audio uninstall removes own persistent state' test ! -d "$PERSIST"
check 'audio uninstall removes runtime state' test ! -d "$MARK"
touch "$W/fixture/fail-mv"
if run post; then bad 'audio partial install fails'; else ok 'audio partial install fails'; fi
check 'audio failed install original identity' cmp -s "$TARGET" "$W/fixture/original"
check 'audio retry after partial failure' run post
check 'audio cleanup retry' run preun
touch "$W/fixture/fail-cp"
if run post; then bad 'audio partial stage copy fails'; else ok 'audio partial stage copy fails'; fi
check 'audio partial stage original identity' cmp -s "$TARGET" "$W/fixture/original"
check 'audio retry after partial stage copy' run post
touch "$W/fixture/fail-cp"
if run preun; then bad 'audio partial restore copy fails'; else ok 'audio partial restore copy fails'; fi
check 'audio partial restore retains verified patched target' cmp -s "$TARGET" "$W/fixture/patched"
check 'audio cleanup after stage copy failure' run preun
run post
rm -rf "$MARK"
check 'audio uninstall directly after data reset' run preun
check 'audio reset uninstall exact original' cmp -s "$TARGET" "$W/fixture/original"
export AUDIO_TEST_REMOUNT_FAIL=rw
if run post; then bad 'audio remount failure rejected'; else ok 'audio remount failure rejected'; fi
check 'audio remount failure original identity' cmp -s "$TARGET" "$W/fixture/original"
unset AUDIO_TEST_REMOUNT_FAIL
# A busy read-only remount (seen on real units) must not fail the install or removal.
export AUDIO_TEST_REMOUNT_FAIL=ro
check 'audio install succeeds when remount ro stays busy' run post
check 'audio busy remount ro still patched' eval '! cmp -s "$TARGET" "$W/fixture/original"'
check 'audio removal succeeds when remount ro stays busy' run preun
check 'audio busy remount ro removal exact original' cmp -s "$TARGET" "$W/fixture/original"
unset AUDIO_TEST_REMOUNT_FAIL
mkdir -p "$MARK"
echo foreign > "$MARK/owner"
echo keep > "$MARK/original"
if run post; then bad 'audio foreign runtime ownership rejected'; else ok 'audio foreign runtime ownership rejected'; fi
check 'audio foreign runtime original preserved' test "$(cat "$MARK/original")" = keep
check 'audio foreign runtime target unchanged' cmp -s "$TARGET" "$W/fixture/original"
rm -rf "$MARK"
run post
echo damaged > "$PERSIST/original"
cp "$W/fixture/original" "$TARGET"
if run post; then bad 'audio damaged persistent backup rejected'; else ok 'audio damaged persistent backup rejected'; fi
check 'audio damaged persistent backup preserved' test "$(cat "$PERSIST/original")" = damaged
cp "$W/fixture/original" "$PERSIST/original"
run preun
echo wrong > "$W/sys/lib/libCarPlayCore.so"
if run post; then bad 'audio unknown decoder rejected'; else ok 'audio unknown decoder rejected'; fi
check 'audio unknown decoder original identity' cmp -s "$TARGET" "$W/fixture/original"
cp "$W/fixture/core" "$W/sys/lib/libCarPlayCore.so"
cp "$W/fixture/original35" "$TARGET"
check 'audio V035 profile automatically selected' run post
check 'audio V035 selected patched bytes' cmp -s "$TARGET" "$W/fixture/patched35"
check 'audio V035 original retained' cmp -s "$PERSIST/original" "$W/fixture/original35"
rm -rf "$MARK"
check 'audio V035 reinstall after reset' run post
check 'audio V035 uninstall selected profile' run preun
check 'audio V035 exact original restored' cmp -s "$TARGET" "$W/fixture/original35"
cp "$W/fixture/originalgl3" "$TARGET"
check 'audio GL3 profile automatically selected' run post
check 'audio GL3 helper made executable' test -x "$W/pkg/bin/audio-patch-v039gl3"
check 'audio GL3 selected patched bytes' cmp -s "$TARGET" "$W/fixture/patchedgl3"
check 'audio GL3 owner records its recipe' test "$(cat "$PERSIST/owner")" = gen5w.kr.audio:testgl3-1
check 'audio GL3 original retained' cmp -s "$PERSIST/original" "$W/fixture/originalgl3"
rm -rf "$MARK"
check 'audio GL3 reinstall after reset' run post
check 'audio GL3 uninstall selected profile' run preun
check 'audio GL3 exact original restored' cmp -s "$TARGET" "$W/fixture/originalgl3"
# Firmware reinstall: the stock library and no system journal, but our runtime
# copy still in /data. Removal drops it; reinstall works; a patched library
# without its journal is never touched.
cp "$W/fixture/original" "$TARGET"
check 'audio install before system reinstall' run post
cp "$W/fixture/original" "$TARGET"; rm -rf "$PERSIST"
check 'audio removal after system reinstall' run preun
check 'audio removal clears the runtime copy' test ! -e "$MARK"
check 'audio removal leaves stock library' cmp -s "$TARGET" "$W/fixture/original"
run post; cp "$W/fixture/original" "$TARGET"; rm -rf "$PERSIST"
check 'audio reinstall after system reinstall' run post
check 'audio reinstall applies' cmp -s "$TARGET" "$W/fixture/patched"
check 'audio removal after that reinstall' run preun
check 'audio removal restores stock' cmp -s "$TARGET" "$W/fixture/original"
run post; echo unknown-firmware > "$TARGET"; rm -rf "$PERSIST"
check 'audio removal on other firmware clears our copy' run preun
check 'audio other firmware library untouched' test "$(cat "$TARGET")" = unknown-firmware
check 'audio other firmware runtime copy cleared' test ! -e "$MARK"
cp "$W/fixture/original" "$TARGET"; run post; rm -rf "$PERSIST"
if run preun; then bad 'audio patched library without journal refused'; else ok 'audio patched library without journal refused'; fi
check 'audio refusal keeps runtime copy' cmp -s "$MARK/original" "$W/fixture/original"
done_tests audio
