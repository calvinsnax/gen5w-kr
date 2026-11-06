#!/bin/bash
. "$(dirname "$0")/lib.sh"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
W=$(mktemp -d); mkdir "$W/dist"
python3 - "$W/dist" <<'PY'
import pathlib,sys,zipfile
for module in ['wireless','audio','bridge','core','timer','bluelink','drivelog']:
 p=pathlib.Path(sys.argv[1])/('gen5w.kr.'+module+'.zip')
 with zipfile.ZipFile(p,'w') as z:
  z.writestr('NEMESIS.data','[nemesis]\nid=gen5w.kr.'+module+'\n')
  z.writestr('scripts/pre.sh','exit 0\n')
PY
check 'build complete integrated USB bundle' python3 "$ROOT/tools/integrated/build.py" --skip-native --dist "$W/dist" --output "$W/usb"
check 'bundle includes staged module gates' test -f "$W/usb/checks/gen5w.kr.bridge/FILES.md5"
check 'source revision metadata uses LF on every build platform' eval '! grep -q "$(printf "\r")" "$W/usb/BUILD-REVISION"'
check 'USB insertion asks NEMESIS to run NEMESIS.sh (Yes/No)' eval 'grep -qx type=execute "$W/usb/NEMESIS.data" && grep -qx path=NEMESIS.sh "$W/usb/NEMESIS.data"'
check 'USB never runs without a dialog' test ! -e "$W/usb/NEMESIS.emergency"
check 'bundle includes ARM snapshot helper' cmp "$ROOT/tools/integrated/bin/zipstore" "$W/usb/zipstore"
check 'build second deterministic bundle' python3 "$ROOT/tools/integrated/build.py" --skip-native --dist "$W/dist" --output "$W/usb-second"
check 'deterministic archive bytes' cmp "$W/usb.zip" "$W/usb-second.zip"
check 'build standard' python3 "$ROOT/tools/integrated/build.py" --skip-native --variant standard --dist "$W/dist" --output "$W/standard"
check 'standard ships no SystemUI or services.odex patch package' eval '! ls "$W/standard/packages" | grep -Eq "gen5w.kr.(notice|hotspot|consent)"'
check 'standard includes the service-only timer' test -f "$W/standard/packages/gen5w.kr.timer.zip"
check 'standard includes the Bluelink reminder service' test -f "$W/standard/packages/gen5w.kr.bluelink.zip"
check 'standard includes the standalone USB drive logger' test -f "$W/standard/packages/gen5w.kr.drivelog.zip"
check 'backend is explicitly builtin' grep -qx builtin "$W/standard/GEN5W-BACKEND"
python3 - "$W/dist" <<'PY'
import pathlib,sys,zipfile
p=pathlib.Path(sys.argv[1])/'gen5w.kr.dongle.zip'
with zipfile.ZipFile(p,'w') as z:
  z.writestr('NEMESIS.data','[nemesis]\nid=gen5w.kr.dongle\n')
  z.writestr('scripts/pre.sh','exit 0\n')
PY
check 'build dongle variant' python3 "$ROOT/tools/integrated/build.py" --skip-native --variant dongle --dist "$W/dist" --output "$W/dongle"
check 'dongle includes dongle package' test -f "$W/dongle/packages/gen5w.kr.dongle.zip"
check 'dongle backend is explicitly dongle' grep -qx dongle "$W/dongle/GEN5W-BACKEND"
check 'local edition cannot be built by public tool' eval '! python3 "$ROOT/tools/integrated/build.py" --skip-native --variant skip-consent --dist "$W/dist" --output "$W/local-refused"'
check 'refused edition creates no files' test ! -e "$W/local-refused"
sed "s#/system/bin/sh#$(command -v mksh)#g" "$W/usb/NEMESIS.sh" > "$W/usb/entry.sh"
mkdir "$W/prop"; printf '#!/bin/sh\necho "${BOOTED-1}"\n' > "$W/prop/getprop"; chmod +x "$W/prop/getprop"
echo 'echo ran' > "$W/usb/status.sh"; echo status > "$W/usb/GEN5W-ACTION"
check 'USB entry refuses while Android is down' eval '! BOOTED=0 PATH="$W/prop:$PATH" mksh "$W/usb/entry.sh" && grep -qx refused=android-not-ready "$W/usb/GEN5W-REPORT/STARTUP.txt"'
check 'USB entry refuses when boot state is unknown' eval '! mksh "$W/usb/entry.sh" | grep -q ran'
export PATH="$W/prop:$PATH"
echo 'echo selected-status' > "$W/usb/status.sh"
printf 'status\r\n' > "$W/usb/GEN5W-ACTION"
check 'USB action selector accepts Windows newline' eval 'mksh "$W/usb/entry.sh" | grep -qx selected-status'
mkdir "$W/no-dirname"
echo '#!/bin/sh' > "$W/no-dirname/dirname"
echo 'exit 127' >> "$W/no-dirname/dirname"
chmod +x "$W/no-dirname/dirname"
MKSH=$(command -v mksh)
check 'USB entry works from outside USB without dirname utility' eval '(cd / && PATH="$W/no-dirname:$PATH" "$MKSH" "$W/usb/entry.sh") | grep -qx selected-status'
check 'vehicle scripts do not require dirname or basename' eval '! grep -En "\\b(dirname|basename)\\b" "$ROOT"/tools/integrated/*.sh "$ROOT"/packages/*/scripts/*.sh "$ROOT"/packages/*/bin/*.sh'
check 'USB entry writes fixed early execution status' grep -qx 'exit=0' "$W/usb/GEN5W-REPORT/STARTUP.txt"
echo 'exit 23' > "$W/usb/status.sh"
check 'USB entry preserves action failure status' eval 'mksh "$W/usb/entry.sh"; [ $? = 23 ]'
check 'USB entry records failure before transaction reporting' grep -qx 'exit=23' "$W/usb/GEN5W-REPORT/STARTUP.txt"
echo 'echo selected-wired' > "$W/usb/wired-only.sh"
echo wired-only > "$W/usb/GEN5W-ACTION"
check 'USB action selects wired-only mode' eval 'mksh "$W/usb/entry.sh" | grep -qx selected-wired'
check 'automatic installer needs no CMD selectors' test ! -f "$W/usb/무선끄기.cmd"
echo 'echo selected-diag' > "$W/usb/diag.sh"
echo diag > "$W/usb/GEN5W-ACTION"
cp "$W/usb/GEN5W-REPORT/STARTUP.txt" "$W/startup-before-diag"
check 'USB action selects the read-only diagnosis' eval 'mksh "$W/usb/entry.sh" | grep -qx selected-diag'
check 'diagnosis keeps the install report files' cmp -s "$W/startup-before-diag" "$W/usb/GEN5W-REPORT/STARTUP.txt"
check 'diagnosis writes its own entry status' eval 'grep -qx action=diag "$W/usb/GEN5W-REPORT/DIAG_STARTUP.txt" && grep -qx exit=0 "$W/usb/GEN5W-REPORT/DIAG_STARTUP.txt" && grep -qx selected-diag "$W/usb/GEN5W-REPORT/DIAG_EXEC_LOG.txt"'
check 'bundle ships the diagnosis action' test -f "$W/standard/diag.sh"
echo unknown > "$W/usb/GEN5W-ACTION"
check 'USB action selector refuses unknown action' eval '! mksh "$W/usb/entry.sh"'
python3 - "$W/dist/gen5w.kr.core.zip" <<'PY'
import zipfile,sys
with zipfile.ZipFile(sys.argv[1],'w') as z:
 z.writestr('NEMESIS.data','[nemesis]\nid=wrong\n')
PY
check 'reject wrong package identity' eval '! python3 "$ROOT/tools/integrated/build.py" --skip-native --dist "$W/dist" --output "$W/rejected"'
check 'invalid bundle creates no output' test ! -e "$W/rejected"
done_tests integrated-build
