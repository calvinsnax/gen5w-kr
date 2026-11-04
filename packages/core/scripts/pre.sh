#!/system/bin/sh
# Core needs the OEM shared APIs; wireless hardware is not required for wired HUD.
SYS=${CORE_TEST_SYS:-/system}
DATA=${CORE_TEST_DATA:-/data}
if [ -d "$DATA/nemesis/apps/wireless.carplay.aa" ]; then
    echo "SKIP core: remove the existing HUD extension through the integrated update first"
    exit 1
fi
for _file in "$SYS/framework/com.tcc.iap2.jar" "$SYS/app/Iap2ServerApp.apk"; do
    [ -f "$_file" ] || { echo "SKIP core: required iAP2 component missing"; exit 77; }
done
_cluster=$SYS/framework/automotive.odex
[ -f "$_cluster" ] && grep -aqF 'updateTPTurnListNew' "$_cluster" && grep -aqF 'updateLaneInfo' "$_cluster" && grep -aqF 'updateTBTInfo' "$_cluster" || {
    echo "SKIP core: required cluster API not identified"
    exit 77
}
_step=$(getprop ro.product.opt.stepofspec)
case "$_step" in ''|*[!0-9]*) _step=0;; esac
if [ "$_step" -lt 999 ]; then
    _bridge=$DATA/nemesis/apps/gen5w.kr.bridge
    _matched=no
    for _version in v035 v039 v039gl3; do
        _tool=$_bridge/bin/iap2-route-patch-$_version
        if [ -x "$_tool" ] && "$_tool" patched "$SYS/app/Iap2ServerApp.odex"; then _matched=yes; break; fi
    done
    [ "$_matched" = yes ] || { echo 'SKIP core: matching route-capability bridge unavailable'; exit 77; }
fi
echo "Core API declarations present; vehicle output is not yet validated"
exit 0
