# Owned, hash-verified library replacement. mksh + Android toolbox only.
# Each entry point sets SCRIPT_DIR explicitly, including bin/status.sh.
. "$SCRIPT_DIR/recipe.sh"
SYS=${AUDIO_TEST_SYS:-/system}
DATA=${AUDIO_TEST_DATA:-/data}
NEM=${AUDIO_TEST_NEM:-/system/xbin/nemesis}
TOOL=${AUDIO_TEST_TOOL:-$SCRIPT_DIR/../bin/audio-patch}
TARGET=$SYS/lib/libCarPlayAudio.so
STATE=$SYS/etc/gen5w-kr-backup/audio
MARK=$DATA/nemesis/backup/gen5w.kr.audio
OWNER=gen5w.kr.audio:$AUDIO_RECIPE
NOREBOOT=$DATA/nemesis/gen5wkr.noreboot

log() { echo "$1"; }
original() { [ -f "$1" ] && [ ! -L "$1" ] && "$TOOL" original "$1"; }
patched() { [ -f "$1" ] && [ ! -L "$1" ] && "$TOOL" patched "$1"; }
owned() { [ -f "$STATE/owner" ] && [ ! -L "$STATE/owner" ] && [ "$(cat "$STATE/owner")" = "$OWNER" ]; }
select_profile() {
    original "$TARGET" && return 0
    patched "$TARGET" && return 0
    for profile in v035 v039gl3; do
        candidate=$SCRIPT_DIR/../bin/audio-patch-$profile
        if [ -x "$candidate" ] && [ -f "$TARGET" ] && [ ! -L "$TARGET" ] &&
           { "$candidate" original "$TARGET" || "$candidate" patched "$TARGET"; }; then
            TOOL=$candidate
            . "$SCRIPT_DIR/recipe-$profile.sh"
            OWNER=gen5w.kr.audio:$AUDIO_RECIPE
            return 0
        fi
    done
    return 0
}
inspect() {
    # NEMESIS extracts files as 0644, regardless of ZIP executable attributes.
    for audio_helper in "$SCRIPT_DIR/../bin/audio-patch" "$SCRIPT_DIR/../bin/audio-patch-v035" "$SCRIPT_DIR/../bin/audio-patch-v039gl3"; do
        if [ -e "$audio_helper" ] || [ -L "$audio_helper" ]; then
            [ -f "$audio_helper" ] && [ ! -L "$audio_helper" ] && chmod 755 "$audio_helper" || return 1
        fi
    done
    [ -x "$TOOL" ] && [ -x "$NEM" ] || { log 'FAIL audio: helper or NEMESIS absent'; return 1; }
    select_profile || return 1
    for audio_path in "$SYS/etc/gen5w-kr-backup" "$DATA/nemesis/backup" "$STATE" "$MARK"; do
        [ ! -L "$audio_path" ] || return 1
    done
    AUDIO_OWNED=no
    if [ -e "$STATE" ]; then
        owned || { log 'FAIL audio: unknown recovery ownership'; return 1; }
        AUDIO_OWNED=yes
        if [ -e "$STATE/original" ] || [ -L "$STATE/original" ]; then
            original "$STATE/original" || { log 'FAIL audio: damaged recovery original'; return 1; }
        fi
    fi
    if [ -e "$MARK" ]; then
        [ -d "$MARK" ] && [ ! -L "$MARK/owner" ] &&
        [ "$(cat "$MARK/owner" 2>/dev/null)" = "$OWNER" ] && original "$MARK/original" || {
            log 'FAIL audio: unknown or damaged runtime backup'; return 1;
        }
    fi
    if original "$TARGET"; then AUDIO_STATE=stock
    elif patched "$TARGET"; then AUDIO_STATE=patched
    else
        log 'SKIP audio: unknown library hash'
        [ "$AUDIO_OWNED" = no ] && return 77
        return 1
    fi
    if [ "$AUDIO_STATE" = patched ]; then
        [ "$AUDIO_OWNED" = yes ] && original "$STATE/original" || {
            log 'FAIL audio: patched library lacks owned original'; return 1;
        }
    fi
    return 0
}
dependencies() {
    "$TOOL" verify "$SYS/lib/libCarPlayCore.so" "$AUDIO_CORE_SHA" &&
    "$TOOL" verify "$SYS/lib/libCarPlayUtils.so" "$AUDIO_UTILS_SHA" &&
    "$TOOL" verify "$SYS/lib/libopus.so" "$AUDIO_OPUS_SHA" && return 0
    log 'SKIP audio: unknown codec/converter dependency'
    [ "$AUDIO_OWNED" = no ] && return 77
    return 1
}
# /system can stay busy for a moment after a change (EBUSY, also seen on a US
# Ioniq 5). Changes are synced and the install reboots, which mounts /system
# read-only again, so a busy remount is a warning, not a failure.
sys_ro() {
    local n=0
    while [ $n -lt 3 ]; do
        "$NEM" remount ro >/dev/null 2>&1 && return 0
        n=$((n + 1)); sleep 1
    done
    echo 'WARN: /system stays writable until the next reboot (remount busy)'
    return 0
}
stage_clear() {
    if [ -e "$TARGET.gen5w-kr-audio.tmp" ] || [ -L "$TARGET.gen5w-kr-audio.tmp" ]; then
        original "$TARGET.gen5w-kr-audio.tmp" || patched "$TARGET.gen5w-kr-audio.tmp" || return 1
        rm "$TARGET.gen5w-kr-audio.tmp" || return 1
    fi
}
restore_target() {
    original "$TARGET" && return 0
    patched "$TARGET" && original "$STATE/original" && stage_clear || return 1
    if cp -p "$STATE/original" "$TARGET.gen5w-kr-audio.tmp" &&
       original "$TARGET.gen5w-kr-audio.tmp" &&
       mv "$TARGET.gen5w-kr-audio.tmp" "$TARGET" && original "$TARGET"; then
        return 0
    fi
    [ -L "$TARGET.gen5w-kr-audio.tmp" ] || rm -f "$TARGET.gen5w-kr-audio.tmp"
    return 1
}
save_original() {
    mkdir -p "$STATE" || return 1
    if ! owned; then
        echo "$OWNER" > "$STATE/owner" || return 1
        chmod 600 "$STATE/owner" || return 1
    fi
    if ! original "$STATE/original"; then
        original "$TARGET" || return 1
        [ ! -L "$STATE/original" ] || return 1
        cp -p "$TARGET" "$STATE/original" && original "$STATE/original" || return 1
    fi
    mkdir -p "$MARK" || return 1
    [ ! -L "$MARK/original" ] && [ ! -L "$MARK/owner" ] || return 1
    cp -p "$STATE/original" "$MARK/original" && original "$MARK/original" || return 1
    echo "$OWNER" > "$MARK/owner" || return 1
    chmod 700 "$STATE" "$MARK" || return 1
    sync
}
cleanup_owned() {
    rm -f "$STATE/original" "$STATE/owner" "$STATE/replacement" || return 1
    rmdir "$STATE" || return 1
    if [ -d "$MARK" ]; then
        [ ! -L "$MARK/owner" ] && [ "$(cat "$MARK/owner" 2>/dev/null)" = "$OWNER" ] || return 1
        rm -f "$MARK/original" "$MARK/owner" || return 1
        rmdir "$MARK" || return 1
    fi
    rmdir "$SYS/etc/gen5w-kr-backup" 2>/dev/null || true
}
# Runtime copy without a system journal: left by a firmware reinstall. Only our
# own fixed files are removed, and never while the patched library is live.
clear_runtime_copy() {
    [ ! -e "$STATE" ] && [ ! -L "$STATE" ] || return 1
    [ -e "$MARK" ] || [ -L "$MARK" ] || return 0
    [ -d "$MARK" ] && [ ! -L "$MARK" ] && [ ! -L "$MARK/original" ] && [ ! -L "$MARK/owner" ] || return 1
    ! patched "$TARGET" || return 1
    case "$(cat "$MARK/owner" 2>/dev/null)" in gen5w.kr.audio:*) ;; *) return 1;; esac
    rm -f "$MARK/original" "$MARK/owner" && rmdir "$MARK" || return 1
    log 'CLEARED audio: runtime copy left by a system reinstall'
}
