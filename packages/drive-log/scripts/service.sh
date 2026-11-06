#!/system/bin/sh
# Independent, fail-closed reader for the dedicated numeric-only app log tag.
SCRIPT_DIR=${0%/*}
[ "$SCRIPT_DIR" != "$0" ] || SCRIPT_DIR=.
. "$SCRIPT_DIR/common.sh"
USB=${DL_USB:-/storage/usb0}
MOUNTS=${DL_MOUNTS:-/proc/mounts}
SYS=${DL_SYS:-/sys}
GETPROP=${DL_GETPROP:-getprop}
LOGCAT=${DL_LOGCAT:-logcat}
DF=${DL_DF:-df}
until [ "$("$GETPROP" sys.boot_completed 2>/dev/null)" = 1 ]; do sleep 5; done

# The service log (stdout) gets one fixed line per state change, so a USB that
# is never written explains why. No path, name or record content is printed.
_dl_note=
dl_note() {
    [ "$1" != "$_dl_note" ] || return 0
    _dl_note=$1
    print -r -- "drive-log: $1"
}
dl_note started
while :; do
    if ! dl_opt_in "$USB"; then dl_note 'waiting: no USB with GEN5W-DEBUG-ON'; sleep 5; continue; fi
    _dl_identity=$(dl_mount_info "$USB" "$MOUNTS" "$SYS")
    case "$_dl_identity" in
        '!'*|'') dl_note "waiting: USB not verified reason=${_dl_identity#!}"; sleep 5; continue;;
    esac
    _dl_source=${_dl_identity%%\|*}
    _dl_path=${_dl_identity##*\|}
    # mksh treats a bare | in these patterns as alternation; keep it escaped.
    _dl_mode=direct
    [ "$_dl_path" = "$USB" ] || _dl_mode=fuse-backing
    (
        # Pin the verified mount as cwd. If it is detached between a check and
        # a write, relative paths still target that filesystem, never the
        # directory exposed underneath /storage/usb0 after unmount.
        cd "$_dl_path" || exit 2
        _dl_after_cd=$(dl_mount_info "$USB" "$MOUNTS" "$SYS") || exit 5
        [ "$_dl_after_cd" = "$_dl_identity" ] && dl_opt_in "$USB" || exit 5
        _dl_start_uptime=$(dl_uptime_ms) || exit 2
        _dl_dir=GEN5W-DRIVELOG
        dl_prepare_ring "$_dl_dir" || exit 2
        _dl_free=$(DL_DF="$DF" dl_free_kb "$_dl_path" "$_dl_source") || exit 3
        [ "$_dl_free" -ge "$DL_MIN_FREE_KB" ] || exit 3
        print -r -- "drive-log: recording mode=$_dl_mode"
        # logcat is a pipe only: no buffer or temporary file is created internally.
        "$LOGCAT" -v raw -s Gen5wDrive:I 2>/dev/null | while :; do
            _dl_wait_start=$(dl_uptime_ms) || exit 5
            _dl_record=
            if IFS= read -t 2 -r _dl_record; then
                dl_opt_in "$USB" || exit 5
                _dl_now=$(dl_mount_info "$USB" "$MOUNTS" "$SYS") || exit 5
                [ "$_dl_now" = "$_dl_identity" ] || exit 5
                dl_validate_record "$_dl_record" || continue
                dl_record_after "$_dl_start_uptime" "$_dl_record" || continue
                _dl_free=$(DL_DF="$DF" dl_free_kb "$_dl_path" "$_dl_source") || exit 3
                dl_write_record "$_dl_dir" "$_dl_record" "$_dl_free" || exit 4
            else
                # mksh read -t reports timeout and EOF alike as nonzero. The
                # timeout takes >=1s; EOF returns immediately. Poll the USB at
                # each idle timeout and terminate the pipe immediately on EOF.
                _dl_wait_end=$(dl_uptime_ms) || exit 5
                dl_read_timeout "$_dl_wait_start" "$_dl_wait_end" || exit 6
                dl_opt_in "$USB" || exit 5
                _dl_idle_mount=$(dl_mount_info "$USB" "$MOUNTS" "$SYS") || exit 5
                [ "$_dl_idle_mount" = "$_dl_identity" ] || exit 5
            fi
        done
    )
    _dl_rc=$?
    _dl_note=
    case "$_dl_rc" in
        2) dl_note 'stopped: cannot prepare GEN5W-DRIVELOG on the USB';;
        3) dl_note 'stopped: USB free space unknown or below 64 MiB';;
        4) dl_note 'stopped: write to USB failed';;
        5) dl_note 'stopped: USB removed, changed or marker removed';;
        6) dl_note 'stopped: log reader ended';;
        *) dl_note "stopped: rc=$_dl_rc";;
    esac
    # On detach, marker removal, low space, or write failure, stop the pipe and
    # wait before reevaluating. No failed record is redirected to internal storage.
    sleep 5
done
