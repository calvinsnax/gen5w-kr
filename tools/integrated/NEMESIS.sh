#!/system/bin/sh
case "$0" in */*) cd "${0%/*}" || exit 1;; esac
action=install
if [ -f GEN5W-ACTION ]; then
    IFS= read -r action < GEN5W-ACTION || [ -n "$action" ] || exit 1
    action=${action%$'\r'}
fi
case "$action" in install|update|rollback|remove|status|wired-only|check|diag) ;;
    *) echo 'REFUSED unknown GEN5W-ACTION'; exit 1;; esac
# Only fixed phase names and exit codes; never copy subprocess output or secrets.
# The read-only diagnosis keeps the install report: it uses its own file names.
start=STARTUP.txt log=EXEC_LOG.txt
[ "$action" != diag ] || { start=DIAG_STARTUP.txt; log=DIAG_EXEC_LOG.txt; }
[ ! -L GEN5W-REPORT ] || exit 1
mkdir -p GEN5W-REPORT || exit 1
[ ! -L "GEN5W-REPORT/$start" ] && [ ! -L "GEN5W-REPORT/$log" ] || exit 1
echo "action=$action" > "GEN5W-REPORT/$start" || exit 1
# NEMESIS 1.15 runs type=execute without asking while Android is down. Only
# run once Android has booted and the Yes/No dialog was answered.
if [ "$(getprop sys.boot_completed 2>/dev/null)" != 1 ]; then
    echo 'refused=android-not-ready' >> "GEN5W-REPORT/$start"
    echo 'REFUSED Android is not ready; plug the USB in again after boot'
    exit 1
fi
/system/bin/sh "./$action.sh" > "GEN5W-REPORT/$log" 2>&1
status=$?
cat "GEN5W-REPORT/$log" 2>/dev/null
echo "exit=$status" >> "GEN5W-REPORT/$start"
sync
exit "$status"
