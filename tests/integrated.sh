#!/bin/bash
. "$(dirname "$0")/lib.sh"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
W=$(mktemp -d); mkdir -p "$W/usb/packages" "$W/data/nemesis/apps" "$W/bin"
cp "$ROOT/tools/integrated/"*.sh "$W/usb/" 2>/dev/null || true
cp "$ROOT/tools/integrated/bin/zipstore-host" "$W/usb/zipstore"
cat > "$W/bin/nemesis" <<'PY'
#!/usr/bin/env python3
import sys,os,zipfile,shutil,subprocess
root=os.environ['IT_DATA']+'/nemesis/apps'; args=sys.argv[1:]
with open(os.environ['IT_DATA']+'/calls','a') as f: f.write(' '.join(args)+'\n')
if args[0]=='pkg-info':
 with zipfile.ZipFile(args[-1]) as z:
  print(z.read('NEMESIS.data').decode().split('id=')[1].splitlines()[0].join(['id=','']))
elif args[0]=='install':
 with zipfile.ZipFile(args[-1]) as z:
  id=z.read('NEMESIS.data').decode().split('id=')[1].splitlines()[0]
  path=root+'/'+id; shutil.rmtree(path,ignore_errors=True); os.makedirs(path); z.extractall(path)
  if os.environ.get('IT_FAIL')==id and '/packages/' in args[-1]: sys.exit(1)
elif args[0]=='uninstall': shutil.rmtree(root+'/'+args[1],ignore_errors=True)
elif args[0]=='root':
 print('RESULT applied')
else: sys.exit(1)
PY
chmod +x "$W/bin/nemesis"
echo '#!/bin/sh' > "$W/bin/sync"
echo 'exit 0' >> "$W/bin/sync"
chmod +x "$W/bin/sync"
python3 - "$W/usb/packages" <<'PY'
import zipfile,sys,hashlib,pathlib
for m in ['dongle','wireless','audio','bridge','core','timer','bluelink','drivelog']:
 with zipfile.ZipFile(sys.argv[1]+'/gen5w.kr.'+m+'.zip','w') as z:
  z.writestr('NEMESIS.data','[nemesis]\nid=gen5w.kr.'+m+'\nversion=new\npreinstall=scripts/pre.sh\npostinstall=scripts/post.sh\n')
  # Injected failures belong to the incoming build (bundle checks/), never to an
  # earlier build reinstalled from the transaction snapshot.
  z.writestr('scripts/pre.sh','case "$PWD" in */checks/*) ;; *) exit 0;; esac\n[ "$IT_PRE_FAIL" != "gen5w.kr.'+m+'" ] || exit 1\n[ "$IT_SKIP" != "gen5w.kr.'+m+'" ] || exit 77\n[ "$IT_REFUSE_REGISTERED" != "gen5w.kr.'+m+'" ] || [ ! -e "$IT_DATA/nemesis/apps/gen5w.kr.'+m+'" ] || exit 1\nexit 0\n')
  z.writestr('scripts/post.sh','[ "$IT_POST_FAIL" != "gen5w.kr.'+m+'" ] || exit 1\nexit 0\n')
  if m=='bridge':
   for t in ('iap2','dipo','gpm'): z.writestr('bin/'+t+'-patch-v039','#!/bin/sh\ncase "$1" in original) grep -q "^stock" "$2";; patched) grep -q "^patched" "$2";; *) exit 1;; esac\n')
  if m=='timer': z.writestr('bin/sha256-check','#!/bin/sh\ncase "$1:$3" in verify:63cf*|verify:97e7*) grep -q "^stock" "$2";; *) exit 1;; esac\n')
 package=pathlib.Path(sys.argv[1])/('gen5w.kr.'+m+'.zip')
 stage=package.parent.parent/'checks'/('gen5w.kr.'+m);stage.mkdir(parents=True)
 sums=[]
 with zipfile.ZipFile(package) as z:
  z.extractall(stage)
  for name in z.namelist(): sums.append(hashlib.md5(z.read(name)).hexdigest()+'  '+name)
 (stage/'FILES.md5').write_text('\n'.join(sums)+'\n')
 (stage/'PACKAGE.md5').write_text(hashlib.md5(package.read_bytes()).hexdigest()+'\n')
PY
mkdir -p "$W/sys/framework" "$W/sys/priv-app"; echo stock > "$W/sys/framework/services.odex"; echo stock > "$W/sys/priv-app/SystemUI.odex"
run() { (cd "$W/usb" && IT_DATA="$W/data" IT_SYSTEM="$W/sys" IT_NEM="$W/bin/nemesis" IT_SHELL=$(command -v mksh) IT_NO_REBOOT=1 CK_TEST_PATH="$W/bin:$PATH" PATH="$W/bin:$PATH" mksh "$1.sh" > "$W/out" 2>&1); }
: > "$W/usb/GEN5W-DEBUG-ON"
check 'integrated install all modules' run install
check 'a committed install with DEBUG-ON arms the read-only diagnosis next' grep -qx diag "$W/usb/GEN5W-ACTION"
rm -f "$W/usb/GEN5W-ACTION" "$W/usb/GEN5W-DEBUG-ON"
check 'seven registered standard module trees' test "$(find "$W/data/nemesis/apps" -name NEMESIS.data | wc -l)" = 7
check 'logger is registered independently of the Probe app' test -f "$W/data/nemesis/apps/gen5w.kr.drivelog/NEMESIS.data"
check 'standard registers the Bluelink reminder service' test -f "$W/data/nemesis/apps/gen5w.kr.bluelink/NEMESIS.data"
check 'standard leaves services.odex stock' grep -qx stock "$W/sys/framework/services.odex"
check 'standard registers the service-only timer' test -f "$W/data/nemesis/apps/gen5w.kr.timer/NEMESIS.data"
check 'standard leaves SystemUI.odex stock' grep -qx stock "$W/sys/priv-app/SystemUI.odex"
check 'standard uses match mode' grep -qx match "$W/data/nemesis/gen5wkr.ap-match"
check 'standard keeps the stock hotspot feature' grep -qx feature "$W/data/nemesis/gen5wkr.ap-hotspot-feature"
check 'transaction committed' grep -qx committed "$W/data/nemesis/gen5w-kr-integrated/state"
check 'reboot suppression removed' test ! -e "$W/data/nemesis/gen5wkr.noreboot"
check 'feature result dashboard generated' grep -q '적용 완료' "$W/usb/GEN5W-REPORT/RESULT.html"
check 'issue attachment generated' test -f "$W/usb/GEN5W-REPORT/ISSUE.md"
TX="$W/data/nemesis/gen5w-kr-integrated"
rm -rf "$TX/prior"; mkdir "$TX/prior"; echo keep-me > "$TX/prior/preserve-marker"; : > "$TX/prior/complete"; : > "$TX/attempt.gen5w.kr.core"
echo future-state > "$TX/state"
check 'update refuses unknown transaction state' eval '! run update && grep -q "unknown transaction state" "$W/out"'
check 'update preserves prior snapshot and journal on unknown state' eval 'grep -qx keep-me "$TX/prior/preserve-marker" && test -f "$TX/prior/complete" && test -f "$TX/attempt.gen5w.kr.core" && grep -qx future-state "$TX/state"'
rm -f "$TX/attempt.gen5w.kr.core"
calls_before=$(grep -cE '^(install|uninstall) ' "$W/data/calls" || true)
check 'remove refuses unknown transaction state' eval 'echo future-state > "$TX/state" && ! run remove && grep -q "unknown transaction state" "$W/out"'
check 'remove does not mutate packages on unknown state' test "$calls_before" = "$(grep -cE '^(install|uninstall) ' "$W/data/calls" || true)"
check 'remove preserves prior snapshot on unknown state' eval 'grep -qx keep-me "$TX/prior/preserve-marker" && test -f "$TX/prior/complete" && grep -qx future-state "$TX/state"'
echo capturing > "$TX/state"
rm -rf "$TX/prior"; mkdir "$TX/prior"; echo incomplete > "$TX/prior/partial-marker"
check 'capturing transaction can retry its snapshot' run update
check 'capturing retry replaces the partial snapshot' eval 'grep -qx committed "$TX/state" && test -f "$TX/prior/complete" && test ! -e "$TX/prior/partial-marker"'
if [ "${IT_TRANSACTION_ONLY:-0}" = 1 ]; then done_tests 'integrated transaction state'; exit $?; fi
export IT_SKIP=gen5w.kr.wireless
check 'unavailable wireless continues installing independent features' run update
unset IT_SKIP
check 'wired fallback retains bridge core timer bluelink and logger' test "$(find "$W/data/nemesis/apps" -name NEMESIS.data | wc -l)" = 5
check 'wired fallback disables Bluetooth transport' test -f "$W/data/nemesis/gen5wkr.wireless-disabled"
check 'wired fallback reports bridge route support' grep -q '유선 HUD 기반' "$W/usb/GEN5W-REPORT/RESULT.md"
check 'rollback wired fallback' run rollback
check 'rollback restores all seven standard modules' test "$(find "$W/data/nemesis/apps" -name NEMESIS.data | wc -l)" = 7
check 'rollback restores prior wireless mode' test ! -e "$W/data/nemesis/gen5wkr.wireless-disabled"
# Update to a next build whose checks do not recognise the earlier build's files:
# the earlier build removes itself first, so the new checks see stock files.
echo bridge_old > "$W/data/nemesis/apps/gen5w.kr.bridge/old.txt"
export IT_REFUSE_REGISTERED=gen5w.kr.bridge
check 'update over an earlier build succeeds' run update
unset IT_REFUSE_REGISTERED
check 'earlier bridge build replaced' test ! -e "$W/data/nemesis/apps/gen5w.kr.bridge/old.txt"
check 'new bridge build registered' test -f "$W/data/nemesis/apps/gen5w.kr.bridge/NEMESIS.data"
check 'update commits' grep -qx committed "$W/data/nemesis/gen5w-kr-integrated/state"
echo core_old > "$W/data/nemesis/apps/gen5w.kr.core/old.txt"
export IT_SKIP=gen5w.kr.core
check 'new build unsupported for one module still updates the rest' run update
unset IT_SKIP
check 'earlier core build kept when the new one is unsupported' grep -qx core_old "$W/data/nemesis/apps/gen5w.kr.core/old.txt"
check 'kept earlier build is reported' grep -q 'SKIPPED gen5w.kr.core: the new build does not support this unit; previous build kept' "$W/data/nemesis/gen5w-kr-integrated/report"
rm -f "$W/data/nemesis/apps/gen5w.kr.core/old.txt"
check 'explicit wired-only mode' run wired-only
check 'explicit wired-only preserves HUD and timer' test -f "$W/data/nemesis/apps/gen5w.kr.timer/NEMESIS.data"
check 'normal update enables wireless again' run update
check 'wireless mode restored after normal update' test ! -e "$W/data/nemesis/gen5wkr.wireless-disabled"

echo usb > "$W/usb/GEN5W-BACKEND"
check 'unavailable USB backend is refused before transaction mutation' eval '! run update'
check 'backend refusal preserves installed modules' test "$(find "$W/data/nemesis/apps" -name NEMESIS.data | wc -l)" = 7
rm "$W/usb/GEN5W-BACKEND"
export IT_SKIP=gen5w.kr.audio
check 'unsupported audio continues with supported modules' run update
unset IT_SKIP
check 'supported modules commit despite unsupported audio' grep -qx committed "$W/data/nemesis/gen5w-kr-integrated/state"
check 'unsupported audio is explicit in dashboard' grep -q '이번 설치에서 제외' "$W/usb/GEN5W-REPORT/RESULT.html"
mkdir -p "$W/data/nemesis/apps/wireless.carplay.aa"
check 'unfinished registration can pass normal original gates' run update
check 'unfinished prior tree stays untouched' test -d "$W/data/nemesis/apps/wireless.carplay.aa"
rmdir "$W/data/nemesis/apps/wireless.carplay.aa"
# Update must snapshot old package trees and restore them on a failed new module.
echo original > "$W/data/nemesis/apps/gen5w.kr.core/old.txt"
export IT_FAIL=gen5w.kr.audio
check 'update failure reported' eval '! run update'
unset IT_FAIL
check 'prior core retained after failure' grep -qx original "$W/data/nemesis/apps/gen5w.kr.core/old.txt"
check 'failed update shown as restored' grep -q '실패 후 이전 상태로 원복' "$W/usb/GEN5W-REPORT/RESULT.md"
check 'explicit rollback' run rollback
check 'update after explicit rollback' run update
echo dongle > "$W/usb/GEN5W-VARIANT"
check 'dongle variant installs eight modules' run update
check 'dongle variant registers dongle module' test -f "$W/data/nemesis/apps/gen5w.kr.dongle/NEMESIS.data"
check 'dongle variant reports dongle feature' grep -q 'USB Wi-Fi 동글 드라이버' "$W/usb/GEN5W-REPORT/RESULT.md"
echo dongle_old > "$W/data/nemesis/apps/gen5w.kr.dongle/old.txt"
export IT_FAIL=gen5w.kr.core
check 'dongle variant update failure rolls back dongle' eval '! run update'
unset IT_FAIL
check 'prior dongle retained after rollback' grep -qx dongle_old "$W/data/nemesis/apps/gen5w.kr.dongle/old.txt"
rm -f "$W/usb/GEN5W-VARIANT"
check 'return to standard variant removes dongle and keeps seven modules' run update
check 'standard variant removes dongle registration' test ! -e "$W/data/nemesis/apps/gen5w.kr.dongle"
check 'standard variant retains seven modules' test "$(find "$W/data/nemesis/apps" -name NEMESIS.data | wc -l)" = 7
check 'rollback after dongle to standard transition restores dongle' run rollback
check 'dongle registration restored after rollback' test -f "$W/data/nemesis/apps/gen5w.kr.dongle/NEMESIS.data"
check 'return to standard variant again' run update
# Safe edition: wired HUD only. Wi-Fi/hotspot/audio and the early-close service
# are removed, and the boot guard recovers after 2 failed boots.
mkdir -p "$W/sys/priv-app" "$W/sys/app"; echo stock > "$W/sys/priv-app/SystemUI.odex"
for f in Iap2ServerApp HKMC_DiPO HKMC_GPM; do echo stock > "$W/sys/app/$f.odex"; done
echo safe > "$W/usb/GEN5W-VARIANT"
rm -rf "$W/usb/GEN5W-REPORT"
check 'safe edition refuses without a pre-install check report' eval '! run update'
check 'missing report reason' grep -q 'no pre-install check report' "$W/data/nemesis/gen5w-kr-integrated/report"
check 'refusal without report changes no modules' test "$(find "$W/data/nemesis/apps" -name NEMESIS.data | wc -l)" = 7
check 'pre-install check passes on stock' run check
check 'check report says install' grep -qx 'verdict=install' "$W/usb/GEN5W-REPORT/CHECK.txt"
cp "$W/usb/GEN5W-REPORT/CHECK.txt" "$W/check.saved"
echo other-build > "$W/usb/BUILD-REVISION"
check 'report from a different build is refused' eval '! run update'
rm -f "$W/usb/BUILD-REVISION"
echo patched > "$W/sys/app/HKMC_GPM.odex"
check 'changed file after the check is refused' eval '! run update'
check 'mismatch is reported' grep -q 'MISMATCH' "$W/data/nemesis/gen5w-kr-integrated/report"
echo stock > "$W/sys/app/HKMC_GPM.odex"
sed -i 's/^verdict=install$/verdict=block/' "$W/usb/GEN5W-REPORT/CHECK.txt"
check 'report that did not say install is refused' eval '! run update'
cp "$W/check.saved" "$W/usb/GEN5W-REPORT/CHECK.txt"
check 'unchanged unit matching the report counts as verified' eval 'run update || true; grep -q "CHECK verified" "$W/data/nemesis/gen5w-kr-integrated/report"'
check 'rollback after verified safe install' run rollback
run check
check 'safe edition installs' run update
check 'safe edition keeps bridge core and standalone logger' test "$(find "$W/data/nemesis/apps" -name NEMESIS.data | wc -l)" = 3
check 'safe edition registers bridge' test -f "$W/data/nemesis/apps/gen5w.kr.bridge/NEMESIS.data"
check 'safe edition registers core' test -f "$W/data/nemesis/apps/gen5w.kr.core/NEMESIS.data"
for m in wireless audio timer bluelink; do
    check "safe edition removes $m" test ! -e "$W/data/nemesis/apps/gen5w.kr.$m"
done
check 'safe edition marks wireless disabled' test -f "$W/data/nemesis/gen5wkr.wireless-disabled"
check 'safe edition plans wired-only without the wireless preflight' eval 'grep "^PLAN " "$W/data/nemesis/gen5w-kr-integrated/report" | tail -n 1 | grep -q "PLAN wired-only"'
check 'safe edition arms boot guard at 2 failures' grep -qx 2 "$W/data/nemesis/gen5wkr.bootguard/max"
check 'safe edition commits' grep -qx committed "$W/data/nemesis/gen5w-kr-integrated/state"
check 'rollback from safe edition restores seven modules' run rollback
check 'seven modules back after safe rollback' test "$(find "$W/data/nemesis/apps" -name NEMESIS.data | wc -l)" = 7
echo patched > "$W/sys/priv-app/SystemUI.odex"
check 'check blocks a SystemUI that is not recognised stock' eval '! run check'
check 'check report says block' grep -qx 'verdict=block' "$W/usb/GEN5W-REPORT/CHECK.txt"
check 'safe edition refuses when SystemUI is not recognised stock' eval '! run update'
check 'refused safe edition keeps seven modules' test "$(find "$W/data/nemesis/apps" -name NEMESIS.data | wc -l)" = 7
check 'refused safe edition reports the reason' grep -q 'REFUSED pre-install check guard' "$W/data/nemesis/gen5w-kr-integrated/report"
echo stock > "$W/sys/priv-app/SystemUI.odex"
# Safe-wireless edition: wireless CarPlay/AA kept, SystemUI and services.odex stock, guard at 2.
echo safe-wireless > "$W/usb/GEN5W-VARIANT"
check 'clean unit for safe-wireless' run remove
run check
: > "$W/usb/GEN5W-WIFI-CLIENT"
check 'safe-wireless refuses the Wi-Fi client opt-in' eval '! run update'
check 'safe-wireless refusal reports the reason' grep -q 'does not enable the Wi-Fi client' "$W/data/nemesis/gen5w-kr-integrated/report"
check 'safe-wireless refusal installs nothing' test "$(find "$W/data/nemesis/apps" -name NEMESIS.data | wc -l)" = 0
rm -f "$W/usb/GEN5W-WIFI-CLIENT"
check 'safe-wireless edition installs' run update
check 'safe-wireless keeps five modules including logger' test "$(find "$W/data/nemesis/apps" -name NEMESIS.data | wc -l)" = 5
for m in wireless audio bridge core; do
    check "safe-wireless registers $m" test -f "$W/data/nemesis/apps/gen5w.kr.$m/NEMESIS.data"
done
check 'safe-wireless leaves services.odex stock' grep -qx stock "$W/sys/framework/services.odex"
check 'safe-wireless writes the match marker' grep -qx match "$W/data/nemesis/gen5wkr.ap-match"
check 'safe-wireless leaves out the hotspot feature' test ! -e "$W/data/nemesis/gen5wkr.ap-hotspot-feature"
check 'safe-wireless removes the timer service' test ! -e "$W/data/nemesis/apps/gen5w.kr.timer"
check 'safe-wireless removes the Bluelink reminder service' test ! -e "$W/data/nemesis/apps/gen5w.kr.bluelink"
check 'safe-wireless keeps wireless enabled' test ! -e "$W/data/nemesis/gen5wkr.wireless-disabled"
check 'safe-wireless plans wireless' eval 'grep "^PLAN " "$W/data/nemesis/gen5w-kr-integrated/report" | tail -n 1 | grep -q "PLAN wireless: supported"'
check 'safe-wireless arms boot guard at 2 failures' grep -qx 2 "$W/data/nemesis/gen5wkr.bootguard/max"
check 'safe-wireless commits' grep -qx committed "$W/data/nemesis/gen5w-kr-integrated/state"
check 'rollback from safe-wireless returns to the clean unit' run rollback
check 'no modules after safe-wireless rollback' test "$(find "$W/data/nemesis/apps" -name NEMESIS.data | wc -l)" = 0
echo patched > "$W/sys/priv-app/SystemUI.odex"
run check
check 'safe-wireless refuses when SystemUI is not recognised stock' eval '! run update'
check 'refused safe-wireless installs nothing' test "$(find "$W/data/nemesis/apps" -name NEMESIS.data | wc -l)" = 0
echo stock > "$W/sys/priv-app/SystemUI.odex"
echo junk > "$W/sys/framework/services.odex"
check 'check blocks an unrecognised services.odex' eval '! run check'
check 'safe-wireless refuses an unrecognised services.odex' eval '! run update'
echo stock > "$W/sys/framework/services.odex"
check 'remove clears the match marker' eval 'run check; run update; run remove; test ! -e "$W/data/nemesis/gen5wkr.ap-match"'
rm -f "$W/usb/GEN5W-VARIANT"
check 'standard boot guard limit stays 3' eval 'rm -f "$W/usb/GEN5W-VARIANT"; run update && grep -qx 3 "$W/data/nemesis/gen5wkr.bootguard/max"'
export IT_PRE_FAIL=gen5w.kr.audio
check 'explicit preinstall refusal reported' eval '! run update'
unset IT_PRE_FAIL
check 'preinstall refusal preserves prior modules' test "$(find "$W/data/nemesis/apps" -name NEMESIS.data | wc -l)" = 7
# Failure happens only in incoming payload; old snapshot hooks remain valid.
cp "$W/usb/checks/gen5w.kr.audio/scripts/post.sh" "$W/post.saved"
echo 'exit 1' > "$W/usb/checks/gen5w.kr.audio/scripts/post.sh"
python3 - "$W/usb/checks/gen5w.kr.audio" <<'PYFIX'
import sys,pathlib,hashlib,zipfile
p=pathlib.Path(sys.argv[1]); f=p/'FILES.md5'
f.write_text('\n'.join(hashlib.md5((p/line.split('  ',1)[1]).read_bytes()).hexdigest()+'  '+line.split('  ',1)[1] for line in f.read_text().splitlines())+'\n')
package=p.parent.parent/'packages'/(p.name+'.zip')
with zipfile.ZipFile(package,'w') as z:
 for line in f.read_text().splitlines():
  name=line.split('  ',1)[1];z.writestr(name,(p/name).read_bytes())
(p/'PACKAGE.md5').write_text(hashlib.md5(package.read_bytes()).hexdigest()+'\n')
PYFIX
check 'explicit postinstall failure reported' eval '! run update'
check 'postinstall failure recovers all previous modules' grep -qx rolled-back "$W/data/nemesis/gen5w-kr-integrated/state"
cp "$W/post.saved" "$W/usb/checks/gen5w.kr.audio/scripts/post.sh"
# Restore original checksum too.
md5sum "$W/post.saved" | cut -d' ' -f1 > "$W/post.hash"
python3 - "$W/usb/checks/gen5w.kr.audio" <<'PYFIX'
import sys,pathlib,hashlib,zipfile
p=pathlib.Path(sys.argv[1]); f=p/'FILES.md5'
f.write_text('\n'.join(hashlib.md5((p/line.split('  ',1)[1]).read_bytes()).hexdigest()+'  '+line.split('  ',1)[1] for line in f.read_text().splitlines())+'\n')
package=p.parent.parent/'packages'/(p.name+'.zip')
with zipfile.ZipFile(package,'w') as z:
 for line in f.read_text().splitlines():
  name=line.split('  ',1)[1];z.writestr(name,(p/name).read_bytes())
(p/'PACKAGE.md5').write_text(hashlib.md5(package.read_bytes()).hexdigest()+'\n')
PYFIX
export IT_SKIP=gen5w.kr.audio
touch "$W/usb/GEN5W-ALLOW-SKIPS"
check 'opt-in unsupported module skips' run update
unset IT_SKIP
rm "$W/usb/GEN5W-ALLOW-SKIPS"
check 'skip preserves previous installed audio' test -f "$W/data/nemesis/apps/gen5w.kr.audio/NEMESIS.data"
echo applying > "$W/data/nemesis/gen5w-kr-integrated/state"
touch "$W/data/nemesis/gen5wkr.noreboot"
check 'power interruption recovers before retry' run update
echo removing > "$W/data/nemesis/gen5w-kr-integrated/state"
touch "$W/data/nemesis/gen5wkr.noreboot"
check 'interrupted removal recovers before retry' run update
# Migration uses only package metadata and its declared hooks.
mkdir -p "$W/data/nemesis/apps/wireless.carplay.aa"
printf '[nemesis]\nid=wireless.carplay.aa\npreuninstall=restore.sh\n' > "$W/data/nemesis/apps/wireless.carplay.aa/NEMESIS.data"
echo 'echo restored > "$IT_DATA/legacy-restored"' > "$W/data/nemesis/apps/wireless.carplay.aa/restore.sh"
check 'legacy metadata migration' run update
check 'legacy declared restore hook called' test -f "$W/data/legacy-restored"
check 'legacy registration removed' test ! -d "$W/data/nemesis/apps/wireless.carplay.aa"
check 'legacy rollback restored package' run rollback
check 'legacy prior registration restored' test -f "$W/data/nemesis/apps/wireless.carplay.aa/NEMESIS.data"
check 'remove all modules' run remove
check 'no module trees after remove' test "$(find "$W/data/nemesis/apps" -name NEMESIS.data | wc -l)" = 0
# A reset removes registrations; the bundle's declared recovery hook restores owned system state.
mkdir -p "$W/sys/etc/gen5w-kr-backup/wireless"
echo 'preuninstall=scripts/preun.sh' >> "$W/usb/checks/gen5w.kr.wireless/NEMESIS.data"
echo '[ ! -d "$IT_SYSTEM/etc/gen5w-kr-backup/wireless" ] || rmdir "$IT_SYSTEM/etc/gen5w-kr-backup/wireless"' > "$W/usb/checks/gen5w.kr.wireless/scripts/preun.sh"
python3 - "$W/usb/checks/gen5w.kr.wireless" <<'PYRESET'
import pathlib,sys,hashlib,zipfile
p=pathlib.Path(sys.argv[1]); names=['NEMESIS.data','scripts/pre.sh','scripts/post.sh','scripts/preun.sh']
(p/'FILES.md5').write_text('\n'.join(hashlib.md5((p/n).read_bytes()).hexdigest()+'  '+n for n in names)+'\n')
package=p.parent.parent/'packages'/(p.name+'.zip')
with zipfile.ZipFile(package,'w') as z:
 for n in names:z.writestr(n,(p/n).read_bytes())
(p/'PACKAGE.md5').write_text(hashlib.md5(package.read_bytes()).hexdigest()+'\n')
PYRESET
check 'removal after data reset uses declared durable hook' run remove
check 'durable state restored after registration loss' test ! -d "$W/sys/etc/gen5w-kr-backup/wireless"
# Firmware reinstall: /system is stock again but /data keeps a module's
# leftovers. The bundle's own removal hook clears them, refusing when told to.
mkdir -p "$W/data/nemesis/gen5wkr.bluelink"
echo 'preuninstall=scripts/preun.sh' >> "$W/usb/checks/gen5w.kr.bluelink/NEMESIS.data"
printf '[ ! -e "$IT_DATA/refuse" ] || exit 1\nrm -rf "$IT_DATA/nemesis/gen5wkr.bluelink"\n' > "$W/usb/checks/gen5w.kr.bluelink/scripts/preun.sh"
python3 - "$W/usb/checks/gen5w.kr.bluelink" <<'PYBL'
import pathlib,sys,hashlib,zipfile
p=pathlib.Path(sys.argv[1]); names=['NEMESIS.data','scripts/pre.sh','scripts/post.sh','scripts/preun.sh']
(p/'FILES.md5').write_text('\n'.join(hashlib.md5((p/n).read_bytes()).hexdigest()+'  '+n for n in names)+'\n')
package=p.parent.parent/'packages'/(p.name+'.zip')
with zipfile.ZipFile(package,'w') as z:
 for n in names:z.writestr(n,(p/n).read_bytes())
(p/'PACKAGE.md5').write_text(hashlib.md5(package.read_bytes()).hexdigest()+'\n')
PYBL
check 'removal clears leftovers after a system reinstall' run remove
check 'leftover Bluelink state cleared' test ! -e "$W/data/nemesis/gen5wkr.bluelink"
check 'cleared leftovers are reported' grep -q 'CLEARED gen5w.kr.bluelink' "$W/data/nemesis/gen5w-kr-integrated/report"
# An earlier build's removal check may not know this case; the bundle's decides.
check 'reinstall after a system reinstall' run install
printf '[nemesis]\nid=gen5w.kr.timer\npreuninstall=scripts/old.sh\n' > "$W/data/nemesis/apps/gen5w.kr.timer/NEMESIS.data"
echo 'exit 1' > "$W/data/nemesis/apps/gen5w.kr.timer/scripts/old.sh"
check 'refused earlier removal check falls back to the bundle' run remove
check 'fallback is reported' grep -q 'RECOVERED gen5w.kr.timer' "$W/data/nemesis/gen5w-kr-integrated/report"
check 'fallback removal unregisters the module' test ! -e "$W/data/nemesis/apps/gen5w.kr.timer"
check 'install again' run install
: > "$W/data/refuse"
check 'removal stops when both checks refuse' eval '! run remove'
check 'refused module stays registered' test -f "$W/data/nemesis/apps/gen5w.kr.bluelink/NEMESIS.data"
check 'refusal is held for manual recovery' grep -qx recovery-required "$W/data/nemesis/gen5w-kr-integrated/state"
rm -f "$W/data/refuse"; echo committed > "$W/data/nemesis/gen5w-kr-integrated/state"; rm -f "$W/data/nemesis/gen5wkr.noreboot"
check 'remove after refusal cleared' run remove
mkdir -p "$W/data/nemesis/backup/gen5w.kr.wireless"; echo legacy > "$W/data/nemesis/backup/gen5w.kr.wireless/saved"
check 'old wireless backup layout is never discarded' eval '! run remove'
check 'old wireless backup kept' test -f "$W/data/nemesis/backup/gen5w.kr.wireless/saved"
rm -rf "$W/data/nemesis/backup/gen5w.kr.wireless"
# A corrupt new package is refused before touching installed state.
echo corrupt >> "$W/usb/packages/gen5w.kr.wireless.zip"
check 'rejects bundle package corruption' eval '! run install'
echo DO_NOT_COLLECT_PRIVATE_LOG > "$W/data/nemesis/gen5w.kr.hotspot.log"
check 'status creates current support document' run status
check 'support document excludes raw logs' eval '! grep -q DO_NOT_COLLECT_PRIVATE_LOG "$W/usb/GEN5W-REPORT/ISSUE.md"'
mkdir -p "$W/data/data/kr.gen5w.core/files"
echo "PRIVATE_ROUTE_NAME" > "$W/data/data/kr.gen5w.core/files/navi-debug.log"
echo APIS_PRESENT_SOURCE_UNOBSERVED > "$W/data/data/kr.gen5w.core/files/hud-native-warning.status"
check 'status includes honest native warning capability' run status
check 'navi-debug.log is never copied to public USB report' test ! -e "$W/usb/GEN5W-REPORT/navi-debug.log"
check 'native warning is never reported as proven live output' grep -q '순정 경고 API 확인 · CarPlay 중 표시 미확인' "$W/usb/GEN5W-REPORT/RESULT.html"
echo DO_NOT_COLLECT_PRIVATE_WARNING > "$W/data/data/kr.gen5w.core/files/hud-native-warning.status"
check 'unrecognized private warning file is ignored' run status
check 'unrecognized warning content does not leave vehicle' eval '! grep -q DO_NOT_COLLECT_PRIVATE_WARNING "$W/usb/GEN5W-REPORT/ISSUE.md"'
arm() { (cd "$W/usb" && IT_DATA="$W/data" IT_SYSTEM="$W/sys" mksh -c '. ./common.sh; arm_next_diag "$1"' arm "$1" > "$W/out" 2>&1); }
rm -f "$W/usb/GEN5W-ACTION" "$W/usb/GEN5W-DEBUG-ON"
check 'commit without DEBUG-ON leaves no next action' eval 'arm install && test ! -e "$W/usb/GEN5W-ACTION"'
: > "$W/usb/GEN5W-DEBUG-ON"
check 'commit with DEBUG-ON arms the read-only diagnosis next' eval 'arm install && grep -qx diag "$W/usb/GEN5W-ACTION"'
check 'commit tells how to install again' grep -q 'NEXT: inserting this USB again saves a read-only diagnosis' "$W/out"
echo update > "$W/usb/GEN5W-ACTION"
check 'an update action is replaced by diag' eval 'arm install && grep -qx diag "$W/usb/GEN5W-ACTION"'
echo remove > "$W/usb/GEN5W-ACTION"
check 'an explicit other action is never replaced' eval 'arm install && grep -qx remove "$W/usb/GEN5W-ACTION"'
rm -f "$W/usb/GEN5W-ACTION"
check 'removal never arms diag' eval 'arm remove && test ! -e "$W/usb/GEN5W-ACTION"'
ln -s "$W/elsewhere" "$W/usb/GEN5W-ACTION"
check 'a linked action file is left alone' eval 'arm install && test -L "$W/usb/GEN5W-ACTION" && test ! -e "$W/elsewhere"'
rm -f "$W/usb/GEN5W-ACTION"
rm -f "$W/usb/GEN5W-ACTION" "$W/usb/GEN5W-DEBUG-ON"
echo recovery-required > "$W/data/nemesis/gen5w-kr-integrated/state"
touch "$W/data/nemesis/gen5wkr.noreboot"
check 'update refuses unresolved system recovery' eval '! run update'
check 'refusal preserves recovery state' grep -qx recovery-required "$W/data/nemesis/gen5w-kr-integrated/state"
done_tests integrated
