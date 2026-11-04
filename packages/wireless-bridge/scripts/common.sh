# Own hash-gated iAP2 capabilities; no OEM executable bytes in this package.
SCRIPT_DIR=${0%/*}
[ "$SCRIPT_DIR" != "$0" ] || SCRIPT_DIR=.
SCRIPT_DIR=$(cd "$SCRIPT_DIR" && pwd) || exit 1
. "$SCRIPT_DIR/recipe.sh"
SYS=${BRIDGE_TEST_SYS:-/system}
DATA=${BRIDGE_TEST_DATA:-/data}
NEM=${BRIDGE_TEST_NEM:-/system/xbin/nemesis}
TARGET=$SYS/app/Iap2ServerApp.odex
APK=$SYS/app/Iap2ServerApp.apk
DIPO_TARGET=$SYS/app/HKMC_DiPO.odex
DIPO_APK=$SYS/app/HKMC_DiPO.apk
GPM_TARGET=$SYS/app/HKMC_GPM.odex
GPM_APK=$SYS/app/HKMC_GPM.apk
STATE=$SYS/etc/gen5w-kr-backup/bridge
MARK=$DATA/nemesis/backup/gen5w.kr.bridge
STAGE=$TARGET.gen5w-kr-bridge.tmp
NOREBOOT=$DATA/nemesis/gen5wkr.noreboot
STOPPING=$DATA/nemesis/gen5wkr.bridge.stopping
# AP start guard state (service.sh, AndroidWifiAp). Install and uninstall start it fresh.
APG=$DATA/nemesis/gen5wkr.apguard
APG_COUNT=$DATA/nemesis/gen5wkr.apguard.count
APG_OFF=$DATA/nemesis/gen5wkr.apguard.off
apguard_reset() {
    for _p in "$APG" "$APG_COUNT" "$APG_OFF"; do [ ! -L "$_p" ] || return 1; done
    rm -f "$APG_COUNT" "$APG_OFF" || return 1
    [ ! -d "$APG" ] || rm -rf "$APG" || return 1
    [ ! -e "$APG" ] && [ ! -e "$APG_COUNT" ] && [ ! -e "$APG_OFF" ]
}
log() { echo "$1"; }
# Drop any stale optimized copies so the newly written /system ODEX files are the
# ones the next boot loads. A mismatched dalvik-cache entry can fail class load.
DALVIK_ROOTS=${BRIDGE_TEST_DALVIK:-"/data/dalvik-cache /data/dalvik-cache/arm /cache/dalvik-cache"}
wipe_dalvik() {
    local _d _n _f
    for _d in $DALVIK_ROOTS; do
        [ -d "$_d" ] || continue
        [ ! -L "$_d" ] || return 1
        for _n in Iap2ServerApp HKMC_DiPO HKMC_GPM; do
            for _f in "$_d"/*"$_n"*; do
                [ -e "$_f" ] || continue
                rm -f "$_f" || return 1
                [ ! -e "$_f" ] || return 1
            done
        done
    done
    return 0
}
original() { [ -f "$1" ] && [ ! -L "$1" ] && { "$TOOL" original "$1" 2>/dev/null || "$ROUTE_TOOL" original "$1"; }; }
route_patched() { [ -f "$1" ] && [ ! -L "$1" ] && "$ROUTE_TOOL" patched "$1"; }
legacy_patched() { [ -f "$1" ] && [ ! -L "$1" ] && "$TOOL" patched "$1"; }
patched() { route_patched "$1" || legacy_patched "$1"; }
dipo_original() { [ -f "$1" ] && [ ! -L "$1" ] && "$DIPO_TOOL" original "$1"; }
dipo_patched() { [ -f "$1" ] && [ ! -L "$1" ] && "$DIPO_TOOL" patched "$1"; }
dipo_previous() {
    typeset previous_shas previous_sha
    case "$VERSION" in
        v035) previous_shas=${BRIDGE_DIPO_PREVIOUS_V035_SHAS:-};;
        v039) previous_shas=${BRIDGE_DIPO_PREVIOUS_V039_SHAS:-};;
        *) return 1;;
    esac
    [ -n "$previous_shas" ] && [ -f "$1" ] && [ ! -L "$1" ] || return 1
    for previous_sha in $previous_shas; do
        [ -n "$previous_sha" ] || continue
        "$DIPO_TOOL" verify "$1" "$previous_sha" && return 0
    done
    return 1
}
gpm_original() { [ -f "$1" ] && [ ! -L "$1" ] && [ -n "$GPM_TOOL" ] && "$GPM_TOOL" original "$1"; }
gpm_patched() { [ -f "$1" ] && [ ! -L "$1" ] && [ -n "$GPM_TOOL" ] && "$GPM_TOOL" patched "$1"; }
owned() { [ -f "$STATE/owner" ] && [ ! -L "$STATE/owner" ] && [ "$(cat "$STATE/owner")" = "$OWNER" ]; }
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
inspect() {
    [ -x "$NEM" ] || return 1
    for bridge_path in "$SYS/etc/gen5w-kr-backup" "$DATA/nemesis/backup" "$STATE" "$MARK" "$TARGET" "$APK" "$DIPO_TARGET" "$DIPO_APK" "$GPM_TARGET" "$GPM_APK" "$STOPPING"; do
        [ ! -L "$bridge_path" ] || { log 'FAIL bridge: symbolic link at managed path'; return 1; }
    done
    # NEMESIS extracts native files as 0644; only our fixed helper names change mode.
    for bridge_version in v035 v039 v039gl3; do
        for bridge_kind in iap2 iap2-route dipo gpm; do
            bridge_tool=$SCRIPT_DIR/../bin/$bridge_kind-patch-$bridge_version
            if [ -f "$bridge_tool" ] && [ ! -L "$bridge_tool" ]; then chmod 755 "$bridge_tool" || return 1; fi
        done
    done
    BRIDGE_OWNED=no
    if [ -e "$STATE" ]; then
        [ -d "$STATE" ] && [ -f "$STATE/owner" ] && [ ! -L "$STATE/owner" ] || return 1
        case "$(cat "$STATE/owner")" in
            gen5w.kr.bridge:v035-1) VERSION=v035;;
            gen5w.kr.bridge:v039-1) VERSION=v039;;
            gen5w.kr.bridge:v039gl3-1) VERSION=v039gl3;;
            *) log 'FAIL bridge: foreign recovery ownership'; return 1;;
        esac
        BRIDGE_OWNED=yes
    else
        VERSION=
        for bridge_version in v035 v039 v039gl3; do
            TOOL=$SCRIPT_DIR/../bin/iap2-patch-$bridge_version
            ROUTE_TOOL=$SCRIPT_DIR/../bin/iap2-route-patch-$bridge_version
            if original "$TARGET" || patched "$TARGET"; then VERSION=$bridge_version; break; fi
        done
        [ -n "$VERSION" ] || { log 'SKIP bridge: unknown stock ODEX hash'; return 77; }
    fi
    TOOL=$SCRIPT_DIR/../bin/iap2-patch-$VERSION
    ROUTE_TOOL=$SCRIPT_DIR/../bin/iap2-route-patch-$VERSION
    DIPO_TOOL=$SCRIPT_DIR/../bin/dipo-patch-$VERSION
    GPM_TOOL=
    GPM_VERSION=
    GPM_APK_SHA=
    OWNER=gen5w.kr.bridge:$VERSION-1
    if original "$TARGET"; then BRIDGE_STATE=stock
    elif route_patched "$TARGET"; then BRIDGE_STATE=route-patched
    elif legacy_patched "$TARGET"; then BRIDGE_STATE=legacy-patched
    else log 'FAIL bridge: owned target changed'; return 1; fi
    if dipo_original "$DIPO_TARGET"; then DIPO_STATE=stock
    elif dipo_patched "$DIPO_TARGET"; then DIPO_STATE=patched
    elif dipo_previous "$DIPO_TARGET"; then DIPO_STATE=previous
    else
        log 'SKIP bridge: unknown or mismatched DiPO ODEX'
        [ "$BRIDGE_OWNED" = no ] && return 77
        return 1
    fi
    GPM_STATE=
    if [ -f "$GPM_TARGET" ]; then
        for gpm_version in v035 v039 v039gl3; do
            GPM_TOOL=$SCRIPT_DIR/../bin/gpm-patch-$gpm_version
            [ -f "$GPM_TOOL" ] && [ -x "$GPM_TOOL" ] || continue
            case "$gpm_version" in
                v035) GPM_APK_SHA=${BRIDGE_GPM_APK_V035_SHA:-};;
                v039) GPM_APK_SHA=${BRIDGE_GPM_APK_V039_SHA:-};;
                v039gl3) GPM_APK_SHA=${BRIDGE_GPM_APK_V039GL3_SHA:-};;
            esac
            [ -n "$GPM_APK_SHA" ] && "$GPM_TOOL" verify "$GPM_APK" "$GPM_APK_SHA" || continue
            if gpm_original "$GPM_TARGET"; then GPM_STATE=stock
            elif gpm_patched "$GPM_TARGET"; then GPM_STATE=patched
            else continue; fi
            GPM_VERSION=$gpm_version
            break
        done
        if [ -z "$GPM_VERSION" ]; then
            log 'SKIP bridge: unknown or mismatched GPM APK/ODEX pair'
            [ "$BRIDGE_OWNED" = no ] && return 77
            return 1
        fi
    fi
    case "$VERSION" in
        v035) APK_SHA=$BRIDGE_APK_V035_SHA; DIPO_APK_SHA=$BRIDGE_DIPO_APK_V035_SHA;;
        v039) APK_SHA=$BRIDGE_APK_V039_SHA; DIPO_APK_SHA=$BRIDGE_DIPO_APK_V039_SHA;;
        v039gl3) APK_SHA=$BRIDGE_APK_V039GL3_SHA; DIPO_APK_SHA=$BRIDGE_DIPO_APK_V039GL3_SHA;;
    esac
    if ! "$TOOL" verify "$APK" "$APK_SHA" || ! "$DIPO_TOOL" verify "$DIPO_APK" "$DIPO_APK_SHA"; then
        log 'SKIP bridge: stock APK and ODEX version do not match'
        [ "$BRIDGE_OWNED" = no ] && return 77
        return 1
    fi
    if [ -n "$GPM_TOOL" ] && [ -f "$GPM_TARGET" ] && [ -n "$GPM_APK_SHA" ]; then
        if ! "$GPM_TOOL" verify "$GPM_APK" "$GPM_APK_SHA"; then
            log 'SKIP bridge: stock GPM APK and ODEX version do not match'
            [ "$BRIDGE_OWNED" = no ] && return 77
            return 1
        fi
    fi
    if [ "$BRIDGE_OWNED" = yes ]; then
        if [ -e "$STATE/original" ] || [ -L "$STATE/original" ]; then
            original "$STATE/original" || { log 'FAIL bridge: durable backup damaged'; return 1; }
        fi
        if [ -e "$STATE/dipooriginal" ] || [ -L "$STATE/dipooriginal" ]; then
            dipo_original "$STATE/dipooriginal" || { log 'FAIL bridge: durable DiPO backup damaged'; return 1; }
        fi
        if [ -n "$GPM_TOOL" ] && [ -f "$GPM_TARGET" ]; then
            if [ -e "$STATE/gpmoriginal" ] || [ -L "$STATE/gpmoriginal" ]; then
                gpm_original "$STATE/gpmoriginal" || { log 'FAIL bridge: durable GPM backup damaged'; return 1; }
            fi
        fi
    fi
    if [ "$BRIDGE_STATE" = route-patched ] || [ "$BRIDGE_STATE" = legacy-patched ] ||
       [ "$DIPO_STATE" = patched ] || [ "$DIPO_STATE" = previous ]; then
        [ "$BRIDGE_OWNED" = yes ] && original "$STATE/original" && dipo_original "$STATE/dipooriginal" || { log 'FAIL bridge: patch lacks owned original pair'; return 1; }
    fi
    if [ "$GPM_STATE" = patched ]; then
        [ "$BRIDGE_OWNED" = yes ] && gpm_original "$STATE/gpmoriginal" || { log 'FAIL bridge: GPM patch lacks owned original'; return 1; }
    fi
    if [ -e "$MARK" ]; then
        [ -d "$MARK" ] && [ ! -L "$MARK/owner" ] && [ "$(cat "$MARK/owner" 2>/dev/null)" = "$OWNER" ] || return 1
        if [ -e "$MARK/original" ] || [ -L "$MARK/original" ]; then original "$MARK/original" || return 1; fi
        if [ -e "$MARK/dipooriginal" ] || [ -L "$MARK/dipooriginal" ]; then dipo_original "$MARK/dipooriginal" || return 1; fi
        if [ -e "$MARK/gpmoriginal" ] || [ -L "$MARK/gpmoriginal" ]; then gpm_original "$MARK/gpmoriginal" || return 1; fi
    fi
}
save_original() {
    mkdir -p "$STATE" || return 1
    if ! owned; then echo "$OWNER" > "$STATE/owner" && chmod 600 "$STATE/owner" || return 1; fi
    if ! original "$STATE/original"; then
        original "$TARGET" && [ ! -L "$STATE/original.tmp" ] || return 1
        cp -p "$TARGET" "$STATE/original.tmp" && original "$STATE/original.tmp" && mv "$STATE/original.tmp" "$STATE/original" || return 1
    fi
    if ! dipo_original "$STATE/dipooriginal"; then
        dipo_original "$DIPO_TARGET" && [ ! -L "$STATE/dipooriginal.tmp" ] || return 1
        cp -p "$DIPO_TARGET" "$STATE/dipooriginal.tmp" && dipo_original "$STATE/dipooriginal.tmp" && mv "$STATE/dipooriginal.tmp" "$STATE/dipooriginal" || return 1
    fi
    if [ -n "$GPM_TOOL" ] && [ -f "$GPM_TARGET" ]; then
        if ! gpm_original "$STATE/gpmoriginal"; then
            gpm_original "$GPM_TARGET" && [ ! -L "$STATE/gpmoriginal.tmp" ] || return 1
            cp -p "$GPM_TARGET" "$STATE/gpmoriginal.tmp" && gpm_original "$STATE/gpmoriginal.tmp" && mv "$STATE/gpmoriginal.tmp" "$STATE/gpmoriginal" || return 1
        fi
    fi
    mkdir -p "$MARK" || return 1
    [ ! -L "$MARK/owner" ] && [ ! -L "$MARK/original.tmp" ] && [ ! -L "$MARK/dipooriginal.tmp" ] || return 1
    echo "$OWNER" > "$MARK/owner" || return 1
    cp -p "$STATE/original" "$MARK/original.tmp" && original "$MARK/original.tmp" && mv "$MARK/original.tmp" "$MARK/original" || return 1
    cp -p "$STATE/dipooriginal" "$MARK/dipooriginal.tmp" && dipo_original "$MARK/dipooriginal.tmp" && mv "$MARK/dipooriginal.tmp" "$MARK/dipooriginal" || return 1
    if [ -n "$GPM_TOOL" ] && [ -f "$GPM_TARGET" ]; then
        [ ! -L "$MARK/gpmoriginal.tmp" ] || return 1
        cp -p "$STATE/gpmoriginal" "$MARK/gpmoriginal.tmp" && gpm_original "$MARK/gpmoriginal.tmp" && mv "$MARK/gpmoriginal.tmp" "$MARK/gpmoriginal" || return 1
    fi
    chmod 700 "$STATE" "$MARK" || return 1
    sync
}
stage_clear_one() {
    typeset stage_path=$1 stage_marker=$2 stage_tool=$3
    [ ! -L "$stage_path" ] && [ ! -L "$stage_marker" ] || return 1
    if [ -e "$stage_path" ]; then
        if ! "$stage_tool" original "$stage_path" && ! "$stage_tool" patched "$stage_path"; then
            [ -f "$stage_marker" ] && [ "$(cat "$stage_marker")" = "$OWNER" ] || return 1
        fi
        rm "$stage_path" || return 1
    fi
    rm -f "$stage_marker"
}
stage_clear() {
    stage_clear_one "$STAGE" "$STATE/staging" "$ROUTE_TOOL" &&
        stage_clear_one "$DIPO_TARGET.gen5w-kr-bridge.tmp" "$STATE/dipostaging" "$DIPO_TOOL" &&
        { [ -z "$GPM_TOOL" ] || [ ! -f "$GPM_TARGET" ] || stage_clear_one "$GPM_TARGET.gen5w-kr-bridge.tmp" "$STATE/gpmstaging" "$GPM_TOOL"; }
}
replace_target() {
    typeset replace_source=$1 replace_kind=$2 replace_path=$3 replace_tool=$4 replace_backup=$5 replace_marker=$6
    typeset replace_stage=$replace_path.gen5w-kr-bridge.tmp
    # Stage retains original mode, uid and gid; rename is atomic.
    stage_clear_one "$replace_stage" "$replace_marker" "$replace_tool" || return 1
    echo "$OWNER" > "$replace_marker" && sync || return 1
    if cp -p "$replace_backup" "$replace_stage" && cat "$replace_source" > "$replace_stage" &&
       "$replace_tool" "$replace_kind" "$replace_stage" && sync && mv "$replace_stage" "$replace_path" && "$replace_tool" "$replace_kind" "$replace_path"; then
        rm -f "$replace_marker"; sync; return 0
    fi
    stage_clear_one "$replace_stage" "$replace_marker" "$replace_tool" || true
    return 1
}
restore_target() {
    typeset restore_rc=0
    if ! original "$TARGET"; then
        patched "$TARGET" && original "$STATE/original" &&
            replace_target "$STATE/original" original "$TARGET" "$TOOL" "$STATE/original" "$STATE/staging" || restore_rc=1
    fi
    if ! dipo_original "$DIPO_TARGET"; then
        { dipo_patched "$DIPO_TARGET" || dipo_previous "$DIPO_TARGET"; } && dipo_original "$STATE/dipooriginal" &&
            replace_target "$STATE/dipooriginal" original "$DIPO_TARGET" "$DIPO_TOOL" "$STATE/dipooriginal" "$STATE/dipostaging" || restore_rc=1
    fi
    if [ -n "$GPM_TOOL" ] && [ -f "$GPM_TARGET" ] && ! gpm_original "$GPM_TARGET"; then
        gpm_patched "$GPM_TARGET" && gpm_original "$STATE/gpmoriginal" &&
            replace_target "$STATE/gpmoriginal" original "$GPM_TARGET" "$GPM_TOOL" "$STATE/gpmoriginal" "$STATE/gpmstaging" || restore_rc=1
    fi
    return "$restore_rc"
}
cleanup_owned() {
    owned && original "$TARGET" && dipo_original "$DIPO_TARGET" &&
        { [ -z "$GPM_TOOL" ] || [ ! -f "$GPM_TARGET" ] || gpm_original "$GPM_TARGET"; } || return 1
    for bridge_file in original original.tmp dipooriginal dipooriginal.tmp gpmoriginal gpmoriginal.tmp replacement diporeplacement gpmreplacement staging dipostaging gpmstaging owner; do
        [ ! -L "$STATE/$bridge_file" ] || return 1
    done
    rm -f "$STATE/original" "$STATE/original.tmp" "$STATE/dipooriginal" "$STATE/dipooriginal.tmp" "$STATE/gpmoriginal" "$STATE/gpmoriginal.tmp" \
         "$STATE/replacement" "$STATE/diporeplacement" "$STATE/gpmreplacement" "$STATE/staging" "$STATE/dipostaging" "$STATE/gpmstaging" "$STATE/owner" && rmdir "$STATE" || return 1
    if [ -d "$MARK" ]; then
        [ ! -L "$MARK/owner" ] && [ "$(cat "$MARK/owner")" = "$OWNER" ] && [ ! -L "$MARK/original.tmp" ] && [ ! -L "$MARK/dipooriginal.tmp" ] || return 1
        rm -f "$MARK/original" "$MARK/original.tmp" "$MARK/dipooriginal" "$MARK/dipooriginal.tmp" "$MARK/gpmoriginal" "$MARK/gpmoriginal.tmp" "$MARK/owner" && rmdir "$MARK" || return 1
    fi
    rmdir "$SYS/etc/gen5w-kr-backup" 2>/dev/null || true
}
# Runtime copies without a system journal: left by a firmware reinstall. Only
# our own fixed files are removed, and never while a patched file is live.
clear_runtime_copy() {
    [ ! -e "$STATE" ] && [ ! -L "$STATE" ] || return 1
    [ -e "$MARK" ] || [ -L "$MARK" ] || return 0
    [ -d "$MARK" ] && [ ! -L "$MARK" ] || return 1
    case "$(cat "$MARK/owner" 2>/dev/null)" in gen5w.kr.bridge:*) ;; *) return 1;; esac
    if [ -n "$TOOL" ]; then ! patched "$TARGET" || return 1; fi
    if [ -n "$DIPO_TOOL" ]; then ! dipo_patched "$DIPO_TARGET" || return 1; fi
    if [ -n "$GPM_TOOL" ]; then ! gpm_patched "$GPM_TARGET" || return 1; fi
    for bridge_file in original original.tmp dipooriginal dipooriginal.tmp gpmoriginal gpmoriginal.tmp owner; do
        [ ! -L "$MARK/$bridge_file" ] || return 1
    done
    rm -f "$MARK/original" "$MARK/original.tmp" "$MARK/dipooriginal" "$MARK/dipooriginal.tmp" "$MARK/gpmoriginal" "$MARK/gpmoriginal.tmp" "$MARK/owner" &&
        rmdir "$MARK" || return 1
    log 'CLEARED bridge: runtime copies left by a system reinstall'
}
