#!/system/bin/sh
# Boot-loop recovery. The integrated installer armed a boot guard before
# rebooting into patched /system; the runtime service invokes this only after the
# unit has failed to reach sys.boot_completed more than the armed number of times.
# It attempts to restore stock files from verified backups and clear stale cache.
# Incomplete plans are refused and journals are retained. Independent access and
# automatic recovery cannot be guaranteed.
#
# VEHICLE-UNVERIFIED: never run on a car until it passes the mock harness and one
# supervised real-unit fault-injection test. A wrong restore can deepen a brick.
SCRIPT_DIR=${0%/*}
[ "$SCRIPT_DIR" != "$0" ] || SCRIPT_DIR=.
SYS=${BG_TEST_SYS:-/system}
DATA=${BG_TEST_DATA:-/data}
NEM=${BG_TEST_NEM:-/system/xbin/nemesis}
BG=$DATA/nemesis/gen5wkr.bootguard
if [ ! -e "$BG" ] && [ ! -L "$BG" ] && [ -d "$BG.previous" ] && [ ! -L "$BG.previous" ]; then
    BG=$BG.previous
fi
DALVIK_ROOTS=${BG_TEST_DALVIK:-"/data/dalvik-cache /data/dalvik-cache/arm /cache/dalvik-cache"}

log() { echo "$1"; [ -d "$BG" ] && echo "$1" >> "$BG/recover.log" 2>/dev/null; }

# Restore one stock original over its target, via a staged temp so a crash mid-copy
# never leaves a half-written boot-critical file in place. The preflight below
# refuses an existing target with no backup: absence alone cannot prove it is stock.
restore_one() {
    local src=$1 dst=$2 tmp=$2.gen5wkr-bg.tmp
    [ -e "$src" ] || return 0
    [ -f "$src" ] && [ ! -L "$src" ] && [ ! -L "$dst" ] || { log "FAIL bootguard: bad restore path $dst"; return 1; }
    [ ! -L "$tmp" ] || rm -f "$tmp" || return 1
    if cp -p "$src" "$tmp" && mv "$tmp" "$dst" && cmp "$src" "$dst" >/dev/null 2>&1 &&
       { [ -n "$BG_TEST_SYS" ] || [ ! -x /system/bin/restorecon ] || /system/bin/restorecon "$dst"; }; then
        log "RESTORED stock: $dst"
        return 0
    fi
    [ -L "$tmp" ] || rm -f "$tmp" 2>/dev/null
    log "FAIL bootguard: restore $dst"
    return 1
}

wipe_dalvik() {
    local d f
    for d in $DALVIK_ROOTS; do
        [ -d "$d" ] || continue
        for f in "$d"/*Iap2ServerApp* "$d"/*HKMC_DiPO* "$d"/*HKMC_GPM*; do
            [ -e "$f" ] || continue
            rm -f "$f" || return 1
            [ ! -e "$f" ] || return 1
        done
    done
    return 0
}

[ -d "$BG" ] && [ ! -L "$BG" ] && [ -f "$BG/armed" ] && [ ! -L "$BG/armed" ] || { log 'REFUSED bootguard: guard is not armed'; exit 1; }
# Conservatively check all targets before remounting or changing any of them.
# Without an installation inventory, even a missing target and backup cannot
# prove that the target was never changed or deleted.
preflight_pair() {
    local src=$1 dst=$2 tool
    shift 2
    [ ! -L "$src" ] && [ ! -L "$dst" ] || return 1
    [ -e "$src" ] || return 1
    [ -f "$src" ] && [ -f "$dst" ] || return 1
    # The same profile must recognize both the original backup and live file.
    # Fail closed if the installed verifier is missing or not executable.
    for tool in "$@"; do
        [ -f "$tool" ] && [ ! -L "$tool" ] && [ -x "$tool" ] || continue
        "$tool" original "$src" >/dev/null 2>&1 || continue
        { "$tool" original "$dst" >/dev/null 2>&1 || "$tool" patched "$dst" >/dev/null 2>&1; } && return 0
    done
    return 1
}
# The bridge installs without a GPM backup only on units that have no
# HKMC_GPM.odex at all; there is nothing to restore there.
preflight_gpm() {
    if [ ! -e "$SYS/etc/gen5w-kr-backup/bridge/gpmoriginal" ] && [ ! -L "$SYS/etc/gen5w-kr-backup/bridge/gpmoriginal" ] &&
       [ ! -e "$SYS/app/HKMC_GPM.odex" ] && [ ! -L "$SYS/app/HKMC_GPM.odex" ]; then
        return 0
    fi
    preflight_pair "$SYS/etc/gen5w-kr-backup/bridge/gpmoriginal" "$SYS/app/HKMC_GPM.odex" "$_apps/gen5w.kr.bridge/bin/gpm-patch-v039" "$_apps/gen5w.kr.bridge/bin/gpm-patch-v039gl3" "$_apps/gen5w.kr.bridge/bin/gpm-patch-v035"
}
guard_digest() {
    local value
    value=$(md5 "$1" 2>/dev/null) || return 1
    set -- $value; echo "$1"
}
preflight_optional_pair() {
    local src=$1 dst=$2 package=$3 label=$4 tool sum
    shift 4
    if [ -e "$src" ] || [ -L "$src" ] || [ -e "${src%/*}" ] || [ -L "${src%/*}" ] ||
       [ -e "$_apps/$package" ] || [ -L "$_apps/$package" ] ||
       [ -e "$DATA/nemesis/backup/$package" ] || [ -L "$DATA/nemesis/backup/$package" ]; then
        preflight_pair "$src" "$dst" "$@"
        return $?
    fi
    [ -d "$BG/verifiers" ] && [ ! -L "$BG/verifiers" ] && [ -f "$dst" ] && [ ! -L "$dst" ] || return 1
    for tool in "$BG/verifiers/$label-v039" "$BG/verifiers/$label-v039gl3" "$BG/verifiers/$label-v035"; do
        [ -f "$tool" ] && [ ! -L "$tool" ] && [ -x "$tool" ] &&
        [ -f "$tool.md5" ] && [ ! -L "$tool.md5" ] || continue
        sum=$(guard_digest "$tool") || continue
        [ ${#sum} -eq 32 ] || continue
        case "$sum" in *[!0123456789abcdefABCDEF]*) continue;; esac
        [ "$sum" = "$(cat "$tool.md5")" ] || continue
        "$tool" original "$dst" >/dev/null 2>&1 && return 0
    done
    return 1
}
_apps=$DATA/nemesis/apps
recovery_roots_valid() {
    local dir
    for dir in "$SYS" "$SYS/etc" "$SYS/etc/gen5w-kr-backup" "$SYS/framework" "$SYS/priv-app" "$SYS/app" "$SYS/lib" "$SYS/wifi" "$DATA" "$DATA/nemesis" "$_apps" "$DATA/nemesis/backup"; do
        [ ! -L "$dir" ] && { [ ! -e "$dir" ] || [ -d "$dir" ]; } || return 1
    done
}
wireless_call() (
    local action=$1
    cd "$_apps/gen5w.kr.wireless" || exit 1
    if [ -n "$BG_TEST_SYS" ]; then
        EN_TEST_SYS=$SYS EN_TEST_DATA=$DATA EN_TEST_NEM=$NEM
        export EN_TEST_SYS EN_TEST_DATA EN_TEST_NEM
    fi
    . ./scripts/common.sh || exit 1
    case "$action" in
        check) state_check ;;
        restore) state_restore retain ;;
        *) exit 1 ;;
    esac
)
wireless_preflight() {
    local app=$_apps/gen5w.kr.wireless state=$SYS/etc/gen5w-kr-backup/wireless mark=$DATA/nemesis/backup/gen5w.kr.wireless f
    WIRELESS_PLAN=no
    if [ ! -e "$state" ] && [ ! -L "$state" ] && [ ! -e "$app" ] && [ ! -L "$app" ] && [ ! -e "$mark" ] && [ ! -L "$mark" ]; then return 0; fi
    [ -d "$state" ] && [ ! -L "$state" ] && [ -d "$app" ] && [ ! -L "$app" ] || return 1
    [ ! -L "$mark" ] && { [ ! -e "$mark" ] || [ -d "$mark" ]; } || return 1
    for f in "$app/scripts" "$app/scripts/common.sh" "$app/scripts/recovery.sh" "$state/owner" "$state/manifest" "$state/manifest.md5" "$state/runtime.ium" "$state/runtime.ium.md5"; do
        [ -e "$f" ] && [ ! -L "$f" ] || return 1
    done
    [ -d "$app/scripts" ] && [ -f "$app/scripts/common.sh" ] && [ -f "$app/scripts/recovery.sh" ] && [ -f "$state/owner" ] || return 1
    [ -s "$state/manifest" ] && [ -f "$state/runtime.ium" ] && [ -f "$state/runtime.ium.md5" ] || return 1
    command -v getprop >/dev/null 2>&1 && command -v setprop >/dev/null 2>&1 || return 1
    wireless_call check || return 1
    WIRELESS_PLAN=yes
}
# USB Wi-Fi dongle edition: the stock Wi-Fi start during boot loads
# /system/wifi/bcmdhd.ko, which that edition replaces with a stand-in. Put the
# stock module back from its durable backup, checked against the stock hash here
# (not through the package scripts, which may be the damaged part).
DONGLE_BACKUP=$SYS/etc/gen5w-kr-backup/dongle/original
DONGLE_TARGET=$SYS/wifi/bcmdhd.ko
DONGLE_STOCK_MD5=${BG_TEST_DONGLE_MD5:-c19ed2e2d065c6c406d0ba95945caebf}
dongle_preflight() {
    local dir=$SYS/etc/gen5w-kr-backup/dongle
    DONGLE_PLAN=no
    if [ ! -e "$dir" ] && [ ! -L "$dir" ] && [ ! -e "$_apps/gen5w.kr.dongle" ] && [ ! -L "$_apps/gen5w.kr.dongle" ]; then return 0; fi
    [ -f "$DONGLE_BACKUP" ] && [ ! -L "$DONGLE_BACKUP" ] && [ ! -L "$dir" ] &&
    [ -f "$DONGLE_TARGET" ] && [ ! -L "$DONGLE_TARGET" ] || return 1
    [ "$(guard_digest "$DONGLE_BACKUP")" = "$DONGLE_STOCK_MD5" ] || return 1
    DONGLE_PLAN=yes
}
recovery_roots_valid && wireless_preflight && dongle_preflight &&
preflight_pair "$SYS/etc/gen5w-kr-backup/bridge/original" "$SYS/app/Iap2ServerApp.odex" \
    "$_apps/gen5w.kr.bridge/bin/iap2-route-patch-v039" "$_apps/gen5w.kr.bridge/bin/iap2-route-patch-v039gl3" "$_apps/gen5w.kr.bridge/bin/iap2-route-patch-v035" \
    "$_apps/gen5w.kr.bridge/bin/iap2-patch-v039" "$_apps/gen5w.kr.bridge/bin/iap2-patch-v039gl3" "$_apps/gen5w.kr.bridge/bin/iap2-patch-v035" &&
preflight_pair "$SYS/etc/gen5w-kr-backup/bridge/dipooriginal" "$SYS/app/HKMC_DiPO.odex" "$_apps/gen5w.kr.bridge/bin/dipo-patch-v039" "$_apps/gen5w.kr.bridge/bin/dipo-patch-v039gl3" "$_apps/gen5w.kr.bridge/bin/dipo-patch-v035" &&
preflight_gpm &&
preflight_optional_pair "$SYS/etc/gen5w-kr-backup/audio/original" "$SYS/lib/libCarPlayAudio.so" gen5w.kr.audio audio "$_apps/gen5w.kr.audio/bin/audio-patch" "$_apps/gen5w.kr.audio/bin/audio-patch-v039gl3" "$_apps/gen5w.kr.audio/bin/audio-patch-v035" || {
    log 'REFUSED bootguard: incomplete or unsafe recovery plan; manual recovery required'
    echo 'recovery-required' > "$BG/recovery-required.tmp" && mv "$BG/recovery-required.tmp" "$BG/recovery-required"
    sync
    exit 1
}
if [ -z "$BG_TEST_SYS" ]; then
    "$NEM" remount rw >/dev/null 2>&1 || { log 'FAIL bootguard: cannot remount system read-write'; exit 1; }
fi
rc=0
restore_one "$SYS/etc/gen5w-kr-backup/bridge/original" "$SYS/app/Iap2ServerApp.odex" || rc=1
restore_one "$SYS/etc/gen5w-kr-backup/bridge/dipooriginal" "$SYS/app/HKMC_DiPO.odex" || rc=1
restore_one "$SYS/etc/gen5w-kr-backup/bridge/gpmoriginal" "$SYS/app/HKMC_GPM.odex" || rc=1
restore_one "$SYS/etc/gen5w-kr-backup/audio/original" "$SYS/lib/libCarPlayAudio.so" || rc=1
[ "$DONGLE_PLAN" != yes ] || restore_one "$DONGLE_BACKUP" "$DONGLE_TARGET" || rc=1
[ "$rc" != 0 ] || [ "$WIRELESS_PLAN" != yes ] || wireless_call restore || rc=1
[ "$rc" = 0 ] && wipe_dalvik || rc=1
sync
if [ -z "$BG_TEST_SYS" ]; then
    "$NEM" remount ro >/dev/null 2>&1 || rc=1
fi

# Mark recovery as done so the next boot does not recover again in a loop, and
# clear the attempt counter. The breadcrumb lets the Manager report what happened.
if [ -d "$BG" ]; then
    if [ "$rc" = 0 ]; then
        echo "recovered rc=0" > "$BG/recovered.tmp" && mv "$BG/recovered.tmp" "$BG/recovered" || rc=1
        [ "$rc" = 0 ] && rm -f "$BG/count" 2>/dev/null
    else
        echo 'recovery-required' > "$BG/recovery-required.tmp" && mv "$BG/recovery-required.tmp" "$BG/recovery-required" || true
    fi
    sync
fi
log "bootguard recovery complete rc=$rc"

# Tests stop here; a real unit cold-boots into the restored stock system.
[ -n "$BG_TEST_SYS" ] && exit "$rc"
[ "$rc" = 0 ] || exit 1
sync
[ -x /system/bin/d_audio ] && /system/bin/d_audio -c reboot force_normal 2>/dev/null
/system/bin/reboot force_normal 2>/dev/null
/system/bin/reboot
exit "$rc"
