#!/bin/bash
# mock test for tools/integrated/diag.sh (read-only USB diagnosis)
. "$(dirname "$0")/lib.sh"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
W=$(mktemp -d); stubs
D=$W/data/nemesis
mkdir -p "$W/usb" "$D/apps/gen5w.kr.timer" "$D/logs/gen5w.kr.timer" "$D/logs/gen5w.kr.drivelog" \
    "$D/gen5w-kr-integrated" "$W/sysfs/class/net/wlan0" "$W/sysfs/class/net/lo" "$W/proc"
cp "$ROOT/tools/integrated/diag.sh" "$W/usb/"
echo 0123abcd > "$W/usb/BUILD-REVISION"
printf '[nemesis]\nid=gen5w.kr.timer\npackage-version=9.9.9\n' > "$D/apps/gen5w.kr.timer/NEMESIS.data"
echo committed > "$D/gen5w-kr-integrated/state"
{
    for i in $(seq 1 600); do echo "timer: state rejected reason=screen n$i"; done
    echo 'timer: state accepted'
    echo 'wifi SSID=MyHomeNetwork'
} > "$D/logs/gen5w.kr.timer/timer.log"
echo 'drive-log: waiting: USB not verified reason=not-usb-storage' > "$D/logs/gen5w.kr.drivelog/drive-log.log"
echo up > "$W/sysfs/class/net/wlan0/operstate"
printf '/dev/block/vold/8:1 /mnt/media_rw/usb0 vfat rw 0 0\n/dev/fuse /storage/usb0 fuse rw 0 0\n/dev/block/mmcblk0p9 /data ext4 rw 0 0\n' > "$W/proc/mounts"
printf 'bcmdhd 500000 0 - Live 0x0\nsnd_soc 1000 0 - Live 0x0\n' > "$W/proc/modules"
cat > "$W/bin/logcat" <<'EOF'
#!/bin/sh
echo '11-04 22:32:31.000 I/ActivityManager( 597): first buffered line'
echo '11-04 22:33:08.860 I/PhoneProjection( 1165): [ f ] getPPWLDInfo(), Not Exist device info'
echo '11-04 22:33:09.000 D/BluetoothSocket( 1): getState(). Returning 12'
echo '11-04 22:33:10.000 I/Gen5wWireless( 9): session result=17'
echo '11-04 22:33:11.000 I/CarPlay_( 9): onBtAudioStatusUpdate DEVICE_NAME: lsh'
echo '11-04 22:33:12.000 D/CarPlay_( 9): device AA:BB:CC:DD:EE:FF connected'
echo '11-04 22:33:13.000 D/CarPlay_( 9): address: 80:96:98:**:**:**;'
echo '11-04 22:33:14.000 D/WifiService( 9): driving the soft AP state machine'
echo '11-04 22:34:19.000 I/Other( 9): last buffered line'
EOF
chmod +x "$W/bin/logcat"
echo 1 > "$W/props/sys.boot_completed"
run() { (cd "$W/usb" && PATH="$W/bin:$PATH" IT_DATA="$W/data" IT_SYSFS="$W/sysfs" IT_PROC="$W/proc" IT_SYSTEM="$W/sys" mksh diag.sh > "$W/out" 2>&1); }
O=$W/usb/GEN5W-REPORT/DIAG-1.txt
check 'diagnosis runs after boot' run
check 'reports the saved file' grep -qx 'SAVED GEN5W-REPORT/DIAG-1.txt' "$W/out"
check 'writes the first numbered file' test -f "$O"
check 'kit revision and package versions' eval 'grep -qx 0123abcd "$O" && grep -qx "gen5w.kr.timer 9.9.9" "$O"'
check 'transaction state' grep -qx committed "$O"
check 'network interfaces with state' eval 'grep -qx "wlan0 up" "$O" && grep -q "^lo " "$O"'
check 'wifi driver modules only' eval 'grep -q bcmdhd "$O" && ! grep -q snd_soc "$O"'
check 'usb mounts include the FUSE view and its vold mount' eval 'grep -q "/dev/fuse /storage/usb0 fuse" "$O" && grep -q "/mnt/media_rw/usb0 vfat" "$O"'
check 'internal storage mounts are not listed' eval '! grep -q mmcblk0p9 "$O"'
check 'service log keeps only its last 400 lines' eval 'grep -qx "timer: state accepted" "$O" && grep -qx "timer: state rejected reason=screen n600" "$O" && ! grep -qx "timer: state rejected reason=screen n200" "$O"'
check 'drive-log refusal reason is collected' grep -q 'reason=not-usb-storage' "$O"
check 'stock projection decision is collected' grep -q 'Not Exist device info' "$O"
check 'bridge lines are collected' grep -q 'Gen5wWireless.*result=17' "$O"
check 'lines with words such as driving are kept' grep -q 'driving the soft AP' "$O"
check 'network names are dropped' eval '! grep -q MyHomeNetwork "$O"'
check 'device names are dropped' eval '! grep -q "DEVICE_NAME" "$O"'
check 'full and masked addresses are dropped' eval '! grep -q "AA:BB:CC" "$O" && ! grep -q "80:96:98" "$O"'
check 'repeated status noise is dropped' eval '! grep -q "getState()" "$O"'
check 'buffer range shows first and last line' eval 'grep -q "first buffered line" "$O" && grep -q "last buffered line" "$O"'
check 'only the completion toast is sent' eval '[ "$(grep -c . "$W/calls")" = 1 ] && grep -q "am broadcast -a com.hkmc.intent.action.TOAST" "$W/calls"'
check 'second run keeps the first file' run
check 'second run writes the next number' eval 'test -f "$W/usb/GEN5W-REPORT/DIAG-2.txt" && test -f "$O"'
echo 0 > "$W/props/sys.boot_completed"
check 'refuses before boot completes' eval '! run && test ! -e "$W/usb/GEN5W-REPORT/DIAG-3.txt"'
done_tests diag
