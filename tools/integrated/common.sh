# Run from the bundle root. All journals and prior packages stay on the unit.
export EV6_TEST_ROOT=1
DATA=${IT_DATA:-/data}
SYS=${IT_SYSTEM:-/system}
NEM=${IT_NEM:-/system/xbin/nemesis}
SH=${IT_SHELL:-/system/bin/sh}
APPS=$DATA/nemesis/apps
TX=$DATA/nemesis/gen5w-kr-integrated
NOREBOOT=$DATA/nemesis/gen5wkr.noreboot
WIRELESS_OFF=$DATA/nemesis/gen5wkr.wireless-disabled
BOOTGUARD=$DATA/nemesis/gen5wkr.bootguard
AP_MATCH=$DATA/nemesis/gen5wkr.ap-match
# Present with the match marker: still declare the stock hotspot feature (menu).
AP_FEATURE=$DATA/nemesis/gen5wkr.ap-hotspot-feature
IDS='gen5w.kr.wireless gen5w.kr.audio gen5w.kr.bridge gen5w.kr.core gen5w.kr.timer gen5w.kr.bluelink gen5w.kr.drivelog'
ALL_IDS=$IDS
SNAPSHOT_IDS="wireless.carplay.aa gen5w.kr.dongle $IDS"
VARIANT=standard
if [ -f GEN5W-VARIANT ]; then
    IFS= read -r VARIANT < GEN5W-VARIANT
    VARIANT=${VARIANT%$'\r'}
    case "$VARIANT" in
        standard|safe|safe-wireless) ;;
        dongle) ;;
        *) echo 'REFUSED unknown bundle variant'; exit 1;;
    esac
fi
BACKEND=builtin
if [ -f GEN5W-BACKEND ]; then
    IFS= read -r BACKEND < GEN5W-BACKEND
    BACKEND=${BACKEND%$'\r'}
fi
if [ "$VARIANT" = dongle ] || [ "$BACKEND" = dongle ]; then
    IDS='gen5w.kr.dongle gen5w.kr.wireless gen5w.kr.audio gen5w.kr.bridge gen5w.kr.core gen5w.kr.timer gen5w.kr.bluelink gen5w.kr.drivelog'
    ALL_IDS=$IDS
fi
[ "$BACKEND" = builtin ] || [ "$BACKEND" = dongle ] || { echo 'REFUSED: USB Wi-Fi backend is not available in this build'; exit 1; }
# Empty GEN5W-FORCE-DONGLE next to this script: use the dongle even with built-in Wi-Fi.
GEN5W_FORCE_DONGLE=
[ ! -f GEN5W-FORCE-DONGLE ] || [ -L GEN5W-FORCE-DONGLE ] || GEN5W_FORCE_DONGLE=1
export GEN5W_FORCE_DONGLE
# Safe editions leave SystemUI (the boot-critical consent screen) stock.
keeps_systemui() { [ "$VARIANT" = safe ] || [ "$VARIANT" = safe-wireless ]; }
REVERSE='gen5w.kr.drivelog gen5w.kr.bluelink gen5w.kr.timer gen5w.kr.core gen5w.kr.bridge gen5w.kr.audio gen5w.kr.wireless gen5w.kr.dongle wireless.carplay.aa'
. ./report.sh
digest() { local v; v=$(md5 "$1" 2>/dev/null) || return 1; set -- $v; echo "$1"; }
report() {
    echo "$1"; echo "$1" >> "$TX/report"
    case "$1" in FAILED*|REFUSED*|MISSING*|RECOVERY*) echo "$1" >> "$TX/failure";; esac
}
set_state() { echo "$1" > "$TX/state.tmp" && mv "$TX/state.tmp" "$TX/state" && sync; }
meta() {
    local section= line
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in '['*']') section=$line;; "$2="*) [ "$section" = '[nemesis]' ] && { echo "${line#*=}"; return 0; };; esac
    done < "$1"
    return 1
}
gate() {
    local tree=$1 name=$2 path helper
    [ -f "$tree/NEMESIS.data" ] || return 1
    # Native ZIP extraction sets every member to 0644, including our helpers.
    for helper in "$tree"/bin/*; do
        [ ! -f "$helper" ] || { [ ! -L "$helper" ] && chmod 755 "$helper"; } || return 1
    done
    path=$(meta "$tree/NEMESIS.data" "$name") || return 0
    case "$path" in ''|/*|*..*|*[!a-zA-Z0-9_./-]*) report 'REFUSED unsafe hook path'; return 1;; esac
    [ -f "$tree/$path" ] && [ ! -L "$tree/$path" ] || return 1
    (cd "$tree" && "$SH" "$path")
}
hook() { gate "$APPS/$1" "$2"; }
durable() {
    case "$1" in
        gen5w.kr.wireless|gen5w.kr.audio|gen5w.kr.bridge|gen5w.kr.dongle)
        [ -d "$SYS/etc/gen5w-kr-backup/${1##*.}" ];; *) return 1;; esac
}
check_stage() {
    local id=$1
    [ -f "checks/$id/FILES.md5" ] && [ -f "checks/$id/PACKAGE.md5" ] || return 1
    [ "$(digest "packages/$id.zip")" = "$(cat "checks/$id/PACKAGE.md5")" ] || return 1
    check_stage_tree "$id"
}
check_stage_tree() {
    local id=$1 sum path extra
    [ -f "checks/$id/FILES.md5" ] || return 1
    while read -r sum path extra; do
        case "$path" in ''|/*|*..*|*[!a-zA-Z0-9_./-]*) return 1;; esac
        [ -z "$extra" ] && [ ! -L "checks/$id/$path" ] || return 1
        [ "$(digest "checks/$id/$path")" = "$sum" ] || return 1
    done < "checks/$id/FILES.md5"
}
# Old wireless layouts kept their only backup in /data; never discard those.
orphaned_wireless_backup() {
    [ "$1" = gen5w.kr.wireless ] || return 1
    [ -e "$DATA/nemesis/backup/$1/saved" ] || [ -L "$DATA/nemesis/backup/$1/saved" ] ||
    [ -e "$DATA/nemesis/backup/$1/installed" ] || [ -L "$DATA/nemesis/backup/$1/installed" ] || return 1
    ! durable "$1"
}
# Our /data state that outlives /system: after a firmware reinstall /system is
# stock again but these remain (runtime copies, persist properties, Bluelink).
leftover() {
    case "$1" in
        gen5w.kr.wireless|gen5w.kr.audio|gen5w.kr.bridge|gen5w.kr.dongle)
            [ -e "$DATA/nemesis/backup/$1" ] || [ -L "$DATA/nemesis/backup/$1" ];;
        gen5w.kr.bluelink)
            [ -e "$DATA/nemesis/gen5wkr.bluelink" ] || [ -L "$DATA/nemesis/gen5wkr.bluelink" ];;
        *) return 1;;
    esac
}
bundle_has() { [ -f "checks/$1/NEMESIS.data" ] && check_stage_tree "$1"; }
bundle_remove_hook() { bundle_has "$1" && gate "$(pwd)/checks/$1" preuninstall; }
# Clear what a module left in /data once nothing of it is installed. The hook
# itself refuses while any of its changes is still live on /system.
sweep() {
    local id=$1
    leftover "$id" || return 0
    if ! bundle_has "$id"; then
        report "LEFTOVER $id: remove it with the bundle that installed it"
        return 0
    fi
    bundle_remove_hook "$id" || { report "REFUSED $id: leftover data while its changes are live"; return 1; }
    report "CLEARED $id: leftovers of an earlier installation"
}
safe_remove() {
    local id=$1
    if [ ! -f "$APPS/$id/NEMESIS.data" ]; then
        if orphaned_wireless_backup "$id"; then
            report 'REFUSED wireless removal: legacy backup has no registered recovery package or durable journal'
            return 1
        fi
        if durable "$id"; then
            check_stage_tree "$id" || return 1
            gate "$(pwd)/checks/$id" preuninstall || return 1
            report "RESTORED $id: recovered durable ownership after data reset"
            return 0
        fi
        sweep "$id"
        return
    fi
    # Native NEMESIS ignores this hook's return value. Check it ourselves first.
    # An earlier build's hook may not know a firmware reinstall; this bundle's
    # verified hook then decides, with the same refusal rules.
    local recovered=0
    if ! hook "$id" preuninstall; then
        bundle_remove_hook "$id" || return 1
        report "RECOVERED $id: removed with this bundle's check after the installed one refused"
        recovered=1
    fi
    # NEMESIS 1.16 runs the installed hook again and keeps the package if it
    # fails. After this bundle's verified hook restored stock, --force (1.16
    # only; never reached on 1.15, which ignores the hook) lets the removal finish.
    if ! "$NEM" uninstall "$id"; then
        [ "$recovered" = 1 ] && [ -f "$APPS/$id/NEMESIS.data" ] || return 1
        "$NEM" uninstall --force "$id" || return 1
        report "FORCED $id: removed after this bundle's check (installed hook still refuses)"
    fi
    if [ -e "$APPS/$id" ]; then
        rm -rf "$APPS/$id" || return 1
    fi
    sweep "$id"
}
snapshot() {
    local id=$1 info tree=$APPS/$1
    if [ "$id" = gen5w.kr.dongle ] && durable "$id"; then
        if [ ! -f "$SYS/etc/gen5w-kr-backup/dongle/files" ] || [ -L "$SYS/etc/gen5w-kr-backup/dongle/files" ] ||
           [ ! -f "$SYS/etc/gen5w-kr-backup/dongle/files.md5" ] || [ -L "$SYS/etc/gen5w-kr-backup/dongle/files.md5" ]; then
            report 'REFUSED dongle transition: legacy installation lacks a file ownership journal'
            return 1
        fi
    fi
    if [ ! -f "$tree/NEMESIS.data" ]; then
        if orphaned_wireless_backup "$id"; then
            report 'REFUSED wireless snapshot: legacy backup has no registered recovery package or durable journal'
            return 1
        fi
        durable "$id" || return 0
        if [ "$id" = gen5w.kr.dongle ] && [ "$VARIANT" != dongle ] && [ "$BACKEND" = builtin ]; then
            report 'REFUSED dongle transition: installed package is missing; restore with the matching bundle first'
            return 1
        fi
        check_stage_tree "$id" || return 1
        tree=$(pwd)/checks/$id
    fi
    [ "$(meta "$tree/NEMESIS.data" id)" = "$id" ] || return 1
    ./zipstore "$tree" "$TX/prior/$id.zip" || return 1
    info=$("$NEM" pkg-info "$TX/prior/$id.zip") || return 1
    echo "$info" | grep -qx "id=$id" || return 1
    digest "$TX/prior/$id.zip" > "$TX/prior/$id.md5" || return 1
    mkdir "$TX/prior/$id" && cp -R "$tree/." "$TX/prior/$id/" || return 1
}
# Reinstall one module's earlier build from this transaction's snapshot. It was
# installed and verified on this unit before, so an "unsupported" (77) answer
# from its own preinstall (e.g. dongle unplugged) does not stop it.
restore_prior() {
    local id=$1 rc
    [ -f "$TX/prior/$id.zip" ] && [ -f "$TX/prior/$id.md5" ] || return 1
    [ "$(digest "$TX/prior/$id.zip")" = "$(cat "$TX/prior/$id.md5")" ] || return 1
    export GEN5W_REINSTALL=1
    gate "$TX/prior/$id" preinstall; rc=$?
    unset GEN5W_REINSTALL
    [ "$rc" = 0 ] || [ "$rc" = 77 ] || return 1
    "$NEM" install "$TX/prior/$id.zip" || return 1
    [ -f "$APPS/$id/NEMESIS.data" ] || return 1
    hook "$id" postinstall
}
rollback_transaction() {
    progress '문제가 생겨 이전 상태로 되돌리는 중입니다. USB를 빼지 마세요.'
    local id rc=0 prc
    [ -f "$TX/prior/complete" ] || { report 'REFUSED incomplete snapshot; no rollback mutation'; return 1; }
    # Restore the mode before re-registering services from the snapshot.
    restore_wireless_mode || {
        set_state recovery-required
        report 'RECOVERY REQUIRED: wireless mode could not be restored'
        return 1
    }
    set_state recovering || return 1
    for id in $REVERSE; do
        [ -f "$TX/attempt.$id" ] || continue
        safe_remove "$id" || { rc=1; break; }
    done
    if [ "$rc" = 0 ]; then
        for id in $SNAPSHOT_IDS; do
            [ -f "$TX/attempt.$id" ] && [ -f "$TX/prior/$id.zip" ] || continue
            [ "$(digest "$TX/prior/$id.zip")" = "$(cat "$TX/prior/$id.md5")" ] || { rc=1; break; }
            if [ "$id" = gen5w.kr.audio ] && [ -f "$WIRELESS_OFF" ]; then
                result "$id" skipped; report "SKIPPED $id: wired-only after rollback"; continue
            fi
            export GEN5W_REINSTALL=1
            gate "$TX/prior/$id" preinstall; prc=$?
            unset GEN5W_REINSTALL
            # 77: the earlier package does not apply now (e.g. Wi-Fi detection
            # inconclusive after its backup was removed). It stays removed, which
            # leaves its targets stock; wireless then falls back to wired-only.
            if [ "$prc" = 77 ]; then
                if [ "$id" = gen5w.kr.wireless ]; then
                    [ ! -L "$WIRELESS_OFF" ] && echo disabled > "$WIRELESS_OFF" || { rc=1; break; }
                fi
                result "$id" skipped; report "SKIPPED $id: earlier build does not apply now; left stock"
                continue
            fi
            [ "$prc" = 0 ] || { rc=1; break; }
            "$NEM" install "$TX/prior/$id.zip" || { rc=1; break; }
            hook "$id" postinstall || { rc=1; break; }
            report "RESTORED $id"
        done
    fi
    if [ "$rc" = 0 ]; then
        set_state rolled-back || { report 'RECOVERY REQUIRED: rollback state could not be recorded'; return 1; }
        if [ "${KEEP_NOREBOOT:-0}" != 1 ]; then
            rm -f "$NOREBOOT" || { report 'RECOVERY REQUIRED: reboot suppression could not be cleared'; return 1; }
        fi
        for id in gen5w.kr.dongle $ALL_IDS; do
            [ -f "$TX/attempt.$id" ] || continue
            case "$(cat "$TX/result.$id" 2>/dev/null)" in failed*) result "$id" failed-restored;; *) result "$id" restored;; esac
        done
    else
        set_state recovery-required; report 'RECOVERY REQUIRED: prior packages retained; no reboot'
        for id in gen5w.kr.dongle $ALL_IDS; do [ ! -f "$TX/attempt.$id" ] || result "$id" recovery-required; done
    fi
    return "$rc"
}
acquire() {
    chmod 755 ./zipstore 2>/dev/null || true
    mkdir -p "$TX" || return 1
    if ! mkdir "$TX/lock" 2>/dev/null; then
        local pid=
        [ ! -f "$TX/lock/pid" ] || pid=$(cat "$TX/lock/pid")
        case "$pid" in ''|*[!0-9]*) rm -rf "$TX/lock" 2>/dev/null || true;; esac
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then report 'REFUSED another transaction is running'; return 1; fi
        rm -rf "$TX/lock" 2>/dev/null || true
        mkdir "$TX/lock" || return 1
    fi
    echo $$ > "$TX/lock/pid"
    trap 'transaction_exit $?' EXIT
}
# A plain reboot may resume a QuickBoot snapshot. A mismatch between a snapshot
# and modified boot-critical ODEX is a possible failure mode; the observed
# vehicle boot loop has not been attributed to this or any other cause.
# Force one full cold boot so the next boot rebuilds a fresh snapshot from a
# consistent /system. Everyday QuickBoot resumes are unaffected (only this
# post-install boot is cold, and that boot is slow anyway for dexopt).
# VEHICLE-UNVERIFIED: the force-normal command path is not confirmed on a real
# unit. Validate on the mock harness and one car before any production use.
cold_reboot() {
    progress '완료했습니다. 곧 재부팅합니다. 재부팅 후 USB를 빼도 됩니다.'
    sync
    [ "${IT_NO_REBOOT:-0}" = 1 ] && return 0
    [ -x /system/bin/d_audio ] && /system/bin/d_audio -c reboot force_normal 2>/dev/null && return 0
    /system/bin/reboot force_normal 2>/dev/null
    /system/bin/reboot
}

# Arm the boot-loop safety net before rebooting into patched /system. The runtime
# service resets only the consecutive-failure count after sys.boot_completed; the
# guard remains armed for a later ignition-cycle failure. If the unit fails to
# boot IT_BOOTGUARD_MAX times, on-boot recovery restores stock from the on-unit
# backups (etc/gen5w-kr-backup/*/original) and cold-boots. Uses only data already
# on the unit, so no USB bundle is required to self-heal.
bootguard_arm() {
    local purpose=${1:-install} stage=$BOOTGUARD.tmp.$$ previous=$BOOTGUARD.previous max item id source name sum path extra found
    # Safe edition: recover after 2 failed boots instead of 3 (reinforcement R1).
    if keeps_systemui; then max=${IT_BOOTGUARD_MAX:-2}; else max=${IT_BOOTGUARD_MAX:-3}; fi
    case "$max" in ''|*[!0-9]*|0) return 1;; esac
    [ ! -L "$BOOTGUARD" ] || return 1
    [ ! -e "$BOOTGUARD" ] || [ -d "$BOOTGUARD" ] || return 1
    [ ! -e "$previous" ] && [ ! -L "$previous" ] || return 1
    [ "${IT_BOOTGUARD_FAIL:-0}" = 1 ] && return 1
    rm -rf "$stage" 2>/dev/null || return 1
    mkdir -p "$stage" || return 1
    mkdir "$stage/verifiers" || { rm -rf "$stage"; return 1; }
    for item in 'gen5w.kr.audio audio-patch audio-v039' 'gen5w.kr.audio audio-patch-v039gl3 audio-v039gl3' 'gen5w.kr.audio audio-patch-v035 audio-v035'; do
        set -- $item; id=$1; source="checks/$1/bin/$2"; name=$3
        [ -e "$source" ] || [ -L "$source" ] || continue
        [ -f "$source" ] && [ ! -L "$source" ] && check_stage_tree "$id" || { rm -rf "$stage"; return 1; }
        found=no
        while read -r sum path extra; do
            if [ "$path" = "bin/$2" ] && [ -z "$extra" ] && [ "$sum" = "$(digest "$source")" ]; then
                found=yes
                break
            fi
        done < "checks/$id/FILES.md5"
        [ "$found" = yes ] || { rm -rf "$stage"; return 1; }
        cp "$source" "$stage/verifiers/$name" && chmod 755 "$stage/verifiers/$name" &&
        digest "$source" > "$stage/verifiers/$name.md5" &&
        [ -s "$stage/verifiers/$name.md5" ] &&
        [ "$(digest "$stage/verifiers/$name")" = "$(cat "$stage/verifiers/$name.md5")" ] || { rm -rf "$stage"; return 1; }
    done
    # A module that is not installed is recovered by proving its target is still
    # stock with the retained verifier. Check that now, so an install never commits
    # behind a guard that would refuse to recover. A removal leaves nothing of ours
    # on /system to recover, so an unrecognised file (e.g. after an official
    # firmware update) must not turn the removal into a rollback.
    for item in 'audio gen5w.kr.audio lib/libCarPlayAudio.so'; do
        [ "$purpose" != remove ] || continue
        set -- $item
        if [ -e "$APPS/$2" ] || [ -L "$APPS/$2" ] || [ -e "$SYS/etc/gen5w-kr-backup/$1" ] || [ -L "$SYS/etc/gen5w-kr-backup/$1" ]; then
            continue
        fi
        found=none
        for source in "$stage/verifiers/$1-v039" "$stage/verifiers/$1-v039gl3" "$stage/verifiers/$1-v035"; do
            [ -f "$source" ] || continue
            found=no
            "$source" original "$SYS/$3" >/dev/null 2>&1 && { found=yes; break; }
        done
        [ "$found" != no ] || { report "FAILED boot-loop guard: $3 is not a recognised stock file"; rm -rf "$stage"; return 1; }
    done
    echo 0 > "$stage/count" || { rm -rf "$stage"; return 1; }
    print -r -- "$max" > "$stage/max" || { rm -rf "$stage"; return 1; }
    echo armed > "$stage/armed" || { rm -rf "$stage"; return 1; }
    sync
    if [ -d "$BOOTGUARD" ]; then
        mv "$BOOTGUARD" "$previous" || { rm -rf "$stage"; return 1; }
        sync
    fi
    mv "$stage" "$BOOTGUARD" || {
        [ ! -d "$previous" ] || mv "$previous" "$BOOTGUARD" || true
        rm -rf "$stage"; sync; return 1;
    }
    sync
    if [ -f "$BOOTGUARD/armed" ] && [ -f "$BOOTGUARD/count" ] && [ -f "$BOOTGUARD/max" ]; then
        return 0
    fi
    # Keep both generations for inspection if post-rename validation fails.
    return 1
}
bootguard_reconcile_previous() {
    local state=$1 previous=$BOOTGUARD.previous dir value field
    [ -e "$previous" ] || [ -L "$previous" ] || return 0
    [ -d "$previous" ] && [ ! -L "$previous" ] || return 1
    for dir in "$previous" "$BOOTGUARD"; do
        [ -e "$dir" ] || [ -L "$dir" ] || continue
        [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
        [ ! -e "$dir/recovery-required" ] && [ ! -L "$dir/recovery-required" ] &&
        [ ! -e "$dir/recovered" ] && [ ! -L "$dir/recovered" ] || return 1
        for field in armed count max; do
            [ -f "$dir/$field" ] && [ ! -L "$dir/$field" ] || return 1
        done
        [ "$(cat "$dir/armed")" = armed ] || return 1
        for field in count max; do
            value=$(cat "$dir/$field") || return 1
            case "$value" in ''|*[!0-9]*) return 1;; esac
        done
    done
    case "$state" in
        rolled-back)
            if [ -d "$BOOTGUARD" ]; then
                rm -rf "$BOOTGUARD" || return 1
                sync
            fi
            mv "$previous" "$BOOTGUARD" || return 1
            sync ;;
        committed)
            [ -d "$BOOTGUARD" ] && [ ! -L "$BOOTGUARD" ] || return 1
            rm -rf "$previous" || return 1
            sync ;;
        *) return 1 ;;
    esac
}
# The boot counter and recovery run only from the bridge service. Refuse to
# commit /system changes that the guard could not recover because the bridge
# skipped itself (e.g. unrecognised ODEX files).
guard_runner_ok() {
    local id
    [ -f "$APPS/gen5w.kr.bridge/NEMESIS.data" ] && [ ! -L "$APPS/gen5w.kr.bridge/NEMESIS.data" ] && return 0
    for id in gen5w.kr.wireless gen5w.kr.audio gen5w.kr.dongle; do
        [ ! -e "$APPS/$id" ] && [ ! -L "$APPS/$id" ] || return 1
    done
    return 0
}
# With GEN5W-DEBUG-ON on this USB, the next insertion saves a read-only
# diagnosis instead of installing again. Deleting GEN5W-ACTION restores install.
arm_next_diag() {
    local current
    [ "$1" != remove ] || return 0
    [ -f GEN5W-DEBUG-ON ] && [ ! -L GEN5W-DEBUG-ON ] && [ -f diag.sh ] || return 0
    [ ! -L GEN5W-ACTION ] || return 0
    if [ -e GEN5W-ACTION ]; then
        [ -f GEN5W-ACTION ] || return 0
        current=
        IFS= read -r current < GEN5W-ACTION
        current=${current%$'\r'}
        case "$current" in install|update|wired-only) ;; *) return 0;; esac
    fi
    echo diag > GEN5W-ACTION || return 0
    report 'NEXT: inserting this USB again saves a read-only diagnosis (GEN5W-ACTION=diag); delete GEN5W-ACTION to install again'
}
finish() {
    if [ "${1:-install}" != remove ] && ! guard_runner_ok; then
        report 'FAILED boot-loop guard: the bridge service that runs it is not installed; refusing to commit'
        rollback_transaction || report 'RECOVERY REQUIRED: boot-loop guard has no runner'
        return 1
    fi
    bootguard_arm "${1:-install}" || {
        report 'FAILED boot-loop guard: refusing to commit or reboot'
        rollback_transaction || report 'RECOVERY REQUIRED: boot-loop guard could not be armed'
        return 1
    }
    set_state committed || {
        rollback_transaction || report 'RECOVERY REQUIRED: commit state could not be written'
        return 1
    }
    sync
    rm -rf "$BOOTGUARD.previous" 2>/dev/null || report 'WARNING: previous boot guard retained'
    rm -f "$NOREBOOT"
    report 'COMMITTED: module hooks checked; vehicle audio/HUD/connection test pending'
    arm_next_diag "${1:-install}"
    write_summary || echo '결과 문서를 USB에 저장하지 못했습니다. Manager 로그를 확인하세요.'
    sync
    [ "${IT_NO_REBOOT:-0}" = 1 ] || cold_reboot
}
begin() {
    BEGIN_MADE_NOREBOOT=0
    begin_steps && return 0
    # A failed start must not leave reboot suppression behind: it stops the
    # wireless bridge and would let a standalone package install through.
    [ "$BEGIN_MADE_NOREBOOT" != 1 ] || rm -f "$NOREBOOT" 2>/dev/null
    return 1
}
begin_steps() {
    local state= id
    if [ -f "$TX/state" ]; then
        state=$(cat "$TX/state" 2>/dev/null)
        case "$state" in
            applying|removing|recovering)
                if [ -f "$TX/prior/complete" ]; then
                    report 'RECOVERING interrupted prior transaction before new operation'
                    rollback_transaction || { report 'REFUSED cannot recover prior transaction'; return 1; }
                else
                    report 'REFUSED interrupted transaction without complete snapshot'
                    return 1
                fi
                ;;
            recovery-required)
                report 'REFUSED unresolved system recovery required'
                return 1
                ;;
            committed|rolled-back|capturing) ;;
            *) report 'REFUSED unknown transaction state; preserve recovery data'; return 1;;
        esac
    fi
    state=$(cat "$TX/state" 2>/dev/null) || state=
    bootguard_reconcile_previous "$state" || {
        report 'REFUSED unresolved previous boot guard; preserve both generations for recovery'
        return 1
    }
    rm -f "$NOREBOOT" 2>/dev/null || true
    set_state capturing || return 1
    rm -rf "$TX/prior" || return 1
    rm -f "$TX"/attempt.*
    mkdir "$TX/prior" || return 1
    : > "$NOREBOOT" || return 1
    BEGIN_MADE_NOREBOOT=1
    # Capture every prior tree before any hook can mutate the system.
    for id in $SNAPSHOT_IDS; do
        snapshot "$id" || { report "FAILED snapshot $id"; return 1; }
    done
    [ ! -L "$WIRELESS_OFF" ] || return 1
    if [ -f "$WIRELESS_OFF" ]; then echo disabled; else echo enabled; fi > "$TX/prior/wireless-mode" || return 1
    [ ! -L "$AP_MATCH" ] && [ ! -L "$AP_FEATURE" ] || return 1
    { [ -f "$AP_MATCH" ] && echo match; [ -f "$AP_FEATURE" ] && echo feature; :; } > "$TX/prior/ap-markers" || return 1
    echo 1 > "$TX/prior/complete" && sync
}
# On-screen progress, so nobody pulls the USB while a step is still running.
progress() {
    [ -x /system/bin/am ] || return 0
    /system/bin/am broadcast -a com.hkmc.intent.action.TOAST -e com.hkmc.intent.extra.TOAST_MESSAGE "Gen5W KR: $1"         --ez com.hkmc.intent.extra.TOAST_POPUPSHOWING true >/dev/null 2>&1 || true
}
step_name() {
    case "$1" in
        gen5w.kr.wireless) echo '무선 연결';; gen5w.kr.audio) echo '무선 오디오';; gen5w.kr.bridge) echo '블루투스 연결';;
        gen5w.kr.core) echo '계기판·HUD 길안내';; gen5w.kr.timer) echo '시동 안내';; gen5w.kr.bluelink) echo '블루링크 안내';;
        gen5w.kr.drivelog) echo 'USB 주행 진단 로그';;
        gen5w.kr.dongle) echo 'USB Wi-Fi 동글';; *) echo "$1";;
    esac
}
install_transaction() {
    local id info rc wireless_ready removed_prior step=0 steps=0
    reset_results
    progress '설치를 시작합니다. 끝나고 재부팅될 때까지 USB를 빼거나 시동을 끄지 마세요.'
    # Safe editions install only onto the exact state a same-build pre-install
    # check (gen5w-kr-check) recorded and approved. Runs before any change.
    if keeps_systemui; then
        "$SH" ./check.sh --verify > "$TX/check-verify" 2>&1
        rc=$?
        while IFS= read -r info; do report "$info"; done < "$TX/check-verify"
        [ "$rc" = 0 ] || { report 'REFUSED pre-install check guard'; return 1; }
    fi
    # Validate every input identity before the first installed package is removed.
    for id in $IDS; do
        [ -f "packages/$id.zip" ] || { result "$id" failed; report "MISSING $id"; return 1; }
        info=$("$NEM" pkg-info "packages/$id.zip") || { result "$id" failed; return 1; }
        echo "$info" | grep -qx "id=$id" || { result "$id" failed; report "REFUSED wrong package identity $id"; return 1; }
        check_stage "$id" || { result "$id" failed; report "REFUSED staged payload integrity $id"; return 1; }
    done
    # android.hardware.wifi.xml (Wi-Fi client) was added on the bricked V039 unit; never in safe-wireless.
    if [ "$VARIANT" = safe-wireless ] && { [ -e GEN5W-WIFI-CLIENT ] || [ -L GEN5W-WIFI-CLIENT ]; }; then
        report 'REFUSED safe-wireless edition does not enable the Wi-Fi client; remove GEN5W-WIFI-CLIENT'; return 1
    fi
    begin || return 1
    # Choose the branch before removing any installed package.
    # The safe edition never touches Wi-Fi/hotspot (prime suspect of the V039 boot loop).
    if [ "$VARIANT" = safe ] || [ "${IT_FORCE_WIRED:-0}" = 1 ]; then rc=77
    else gate "$(pwd)/checks/gen5w.kr.wireless" preinstall; rc=$?; fi
    case "$rc" in
        0) wireless_ready=yes; report 'PLAN wireless: supported';;
        77) wireless_ready=no; report 'PLAN wired-only: wireless unavailable; restore wireless changes first';;
        78) [ ! -e "$WIRELESS_OFF" ] && [ ! -L "$WIRELESS_OFF" ] || {
                result gen5w.kr.wireless failed; report 'FAILED inconsistent wireless mode'; rollback_transaction; return 1;
            }
            wireless_ready=preserve; report 'PLAN wireless: detection inconclusive; preserve verified existing configuration';;
        *) result gen5w.kr.wireless failed
           report "FAILED wireless preflight rc=$rc"
           rollback_transaction; return 1;;
    esac
    set_state applying || return 1
    # Match mode: every wireless edition keeps services.odex stock. The bridge
    # starts the AP through the stock Wi-Fi service with the CarPlay name and key,
    # then saves the ordinary hotspot name and key back. standard/dongle still
    # declare the stock hotspot feature (hotspot menu); safe-wireless does not.
    [ ! -L "$AP_MATCH" ] && [ ! -L "$AP_FEATURE" ] || { rollback_transaction; return 1; }
    if [ "$VARIANT" = safe ]; then
        rm -f "$AP_MATCH" "$AP_FEATURE" || { rollback_transaction; return 1; }
    else
        echo match > "$AP_MATCH" || { rollback_transaction; return 1; }
        if [ "$VARIANT" = safe-wireless ]; then rm -f "$AP_FEATURE"; else echo feature > "$AP_FEATURE"; fi ||
            { rollback_transaction; return 1; }
    fi
    if [ -e "$APPS/wireless.carplay.aa" ]; then
        if [ -f "$APPS/wireless.carplay.aa/NEMESIS.data" ]; then
            : > "$TX/attempt.wireless.carplay.aa"; sync
            safe_remove wireless.carplay.aa || { rollback_transaction; return 1; }
            report 'MIGRATED wireless.carplay.aa (prior package retained on unit)'
        else
            report 'PRESERVED incomplete prior package; checking original files for normal installation'
        fi
    fi
    # Switching from the dongle edition: its own uninstall restores stock first.
    if [ "$VARIANT" != dongle ] && [ "$BACKEND" = builtin ]; then
        id=gen5w.kr.dongle
        if [ -f "$APPS/$id/NEMESIS.data" ] || durable "$id"; then
            : > "$TX/attempt.$id"; sync
            safe_remove "$id" || {
                result "$id" failed
                report "FAILED restoring previous dongle package $id"
                rollback_transaction
                return 1
            }
            result "$id" disabled
            report "RESTORED $id: switched to standard built-in Wi-Fi mode"
        fi
    fi
    for id in $IDS; do
        # The early close is a service only. Safe editions keep the stock 10 seconds.
        if keeps_systemui && [ "$id" = gen5w.kr.timer ]; then
            : > "$TX/attempt.$id"; sync
            safe_remove "$id" || { result "$id" failed; report "FAILED removing $id for safe edition"; rollback_transaction; return 1; }
            result "$id" skipped
            report "SKIPPED $id: safe edition keeps the stock 10 second warning"
            continue
        fi
        # Safe editions stay minimal: the Bluelink reminder stays stock too.
        if keeps_systemui && [ "$id" = gen5w.kr.bluelink ]; then
            : > "$TX/attempt.$id"; sync
            safe_remove "$id" || { result "$id" failed; report "FAILED removing $id for safe edition"; rollback_transaction; return 1; }
            result "$id" skipped
            report "SKIPPED $id: safe edition keeps the stock Bluelink reminder"
            continue
        fi
        # Native NEMESIS ignores hook exit status. Gate before removing any old module.
        if [ "$wireless_ready" = preserve ]; then
            case "$id" in gen5w.kr.wireless|gen5w.kr.audio)
                if [ -f "$APPS/$id/NEMESIS.data" ] && [ ! -L "$APPS/$id/NEMESIS.data" ] &&
                   [ ! -L "$APPS/$id" ] && [ "$(meta "$APPS/$id/NEMESIS.data" id)" = "$id" ]; then
                    result "$id" preserved; report "PRESERVED $id: wireless detection inconclusive"
                else
                    result "$id" skipped; report "SKIPPED $id: no registered prior package; existing files retained"
                fi
                continue;; esac
        fi
        if [ -f "$WIRELESS_OFF" ]; then
            case "$id" in gen5w.kr.audio)
                result "$id" skipped; report "SKIPPED $id: wired-only mode"; continue;; esac
        fi
        # Update: an installed earlier build removes itself first through its own
        # verified uninstall (stock bytes back), so the new build's checks see stock
        # files instead of the older build's patches. Any later failure rolls back
        # to the snapshot of the earlier build.
        removed_prior=no
        if [ "$id" != gen5w.kr.wireless ] && [ -f "$APPS/$id/NEMESIS.data" ]; then
            : > "$TX/attempt.$id"; sync
            safe_remove "$id" || { result "$id" failed; report "FAILED removing previous $id"; rollback_transaction; return 1; }
            removed_prior=yes
        fi
        if [ "$id" = gen5w.kr.wireless ]; then
            if [ "$wireless_ready" = yes ]; then rc=0; else rc=77; fi
        elif [ "$removed_prior" = yes ]; then
            export GEN5W_REINSTALL=1; gate "$(pwd)/checks/$id" preinstall; rc=$?; unset GEN5W_REINSTALL
        else gate "$(pwd)/checks/$id" preinstall; rc=$?; fi
        if [ "$rc" = 77 ] && [ "$removed_prior" = yes ]; then
            restore_prior "$id" || {
                result "$id" failed; report "FAILED restoring previous $id"; rollback_transaction; return 1;
            }
            result "$id" skipped
            report "SKIPPED $id: the new build does not support this unit; previous build kept"
            continue
        fi
        if [ "$id" = gen5w.kr.wireless ] && [ "$rc" = 77 ]; then
            disable_wireless || { rollback_transaction; return 1; }
            continue
        fi
        if [ "$rc" = 77 ]; then
            result "$id" skipped
            report "SKIPPED $id: unsupported preinstall; prior installation retained"
            continue
        fi
        if [ "$rc" != 0 ]; then
            result "$id" failed
            report "FAILED preinstall $id rc=$rc"
            rollback_transaction || return 1
            return 1
        fi
        if [ "$id" = gen5w.kr.wireless ]; then
            [ ! -L "$WIRELESS_OFF" ] && rm -f "$WIRELESS_OFF" || { rollback_transaction; return 1; }
        fi
        : > "$TX/attempt.$id"; sync
        step=$((step + 1)); steps=0; for info in $IDS; do steps=$((steps + 1)); done
        progress "설치 중 ($step/$steps) $(step_name "$id"). USB를 빼지 마세요."
        safe_remove "$id" || {
            result "$id" failed; rollback_transaction; return 1;
        }
        "$NEM" install "$(pwd)/packages/$id.zip"
        rc=$?
        if [ "$rc" != 0 ] || [ ! -f "$APPS/$id/NEMESIS.data" ]; then
            result "$id" failed
            report "FAILED $id rc=$rc"
            rollback_transaction; return 1
        fi
        hook "$id" postinstall || {
            result "$id" failed; report "FAILED postinstall $id"; rollback_transaction; return 1;
        }
        if [ "$id" = gen5w.kr.bridge ] && [ -f "$WIRELESS_OFF" ]; then result "$id" wired-only
        else result "$id" applied; fi
        report "INSTALLED $id"
    done
    finish
}

# Restore wireless-only changes while retaining the bridge's wired route APIs.
disable_wireless() {
    local item
    [ ! -L "$WIRELESS_OFF" ] || return 1
    echo disabled > "$WIRELESS_OFF" || return 1
    if [ -x /system/bin/am ]; then
        /system/bin/am broadcast -a kr.gen5w.wireless.STOP_BRIDGE >/dev/null 2>&1 || true
    fi
    for item in gen5w.kr.audio gen5w.kr.wireless; do
        : > "$TX/attempt.$item"; sync
        safe_remove "$item" || { result "$item" failed; report "FAILED wireless disable $item"; return 1; }
        result "$item" skipped
    done
    report 'WIRED ONLY: wireless settings restored; independent features continue'
}

restore_ap_markers() {
    [ -f "$TX/prior/ap-markers" ] || return 0
    [ ! -L "$AP_MATCH" ] && [ ! -L "$AP_FEATURE" ] || return 1
    rm -f "$AP_MATCH" "$AP_FEATURE" || return 1
    ! grep -qx match "$TX/prior/ap-markers" || echo match > "$AP_MATCH" || return 1
    ! grep -qx feature "$TX/prior/ap-markers" || echo feature > "$AP_FEATURE" || return 1
}
restore_wireless_mode() {
    restore_ap_markers || return 1
    [ -f "$TX/prior/wireless-mode" ] || return 0
    [ ! -L "$WIRELESS_OFF" ] || return 1
    case "$(cat "$TX/prior/wireless-mode")" in
        disabled) echo disabled > "$WIRELESS_OFF";;
        enabled) rm -f "$WIRELESS_OFF";;
        *) return 1;;
    esac
}
