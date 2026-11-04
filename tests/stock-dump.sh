#!/bin/bash
# mock test for tools/stock-dump (read-only copy of stock files + PC verifier)
. "$(dirname "$0")/lib.sh"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
S=$ROOT/tools/stock-dump
PY=${PYTHON:-python3}
W=$(mktemp -d); stubs; R=$W/root; U=$R/storage/usb0
mkdir -p $U $R/system/app $R/system/priv-app $R/system/framework $R/system/lib $R/system/wifi \
    $R/system/onebin/gl3hev_kr $R/system/etc $R/data/nemesis/apps/nemesis.manager
cp "$S/NEMESIS.sh" "$S/NEMESIS.data" $U/
for f in app/Iap2ServerApp.odex app/Iap2ServerApp.apk app/HKMC_DiPO.odex app/HKMC_DiPO.apk \
         app/HKMC_GPM.odex app/HKMC_GPM.apk priv-app/SystemUI.odex priv-app/SystemUI.apk \
         framework/services.odex framework/services.jar framework/core.odex framework/automotive.odex \
         lib/libCarPlayAudio.so wifi/bcmdhd.ko; do
    echo "stock $f" > "$R/system/$f"
done
echo 'feature list' > $R/system/onebin/gl3hev_kr/featurexml.cfg
ln -s ../app/HKMC_GPM.odex $R/system/lib/libCarPlayCore.so
echo 1 > $W/props/sys.boot_completed
echo GL3HEV.KOR.0000.V039.001.260902 > $W/props/ro.build.product
echo /system/onebin/gl3hev_kr > $W/props/ro.mobis.targetdir
snap() { (cd $R && find system data -exec ls -ld --time-style=+%s {} + | sort; find system data -type f -exec md5sum {} + | sort); }
before=$(snap)
run() { (cd $W && GEN5W_TEST_PATH=$W/bin:$PATH STOCK_TEST_ROOT=$R mksh "$U/NEMESIS.sh") >/dev/null 2>&1; }

check 'dump succeeds' run
O=$U/GEN5W-STOCK; M=$O/MANIFEST.txt
check 'nothing under /system or /data changed' test "$before" = "$(snap)"
check 'records firmware' grep -qx 'firmware=GL3HEV.KOR.0000.V039.001.260902' $M
check 'records no gen5w backup' grep -qx 'gen5w_backup=absent' $M
check 'records other NEMESIS apps' grep -qx 'nemesis_apps=nemesis.manager' $M
check 'result complete' grep -qx 'result=complete' $M
for f in app/HKMC_GPM.odex priv-app/SystemUI.odex framework/services.odex framework/core.odex lib/libCarPlayAudio.so wifi/bcmdhd.ko onebin/gl3hev_kr/featurexml.cfg; do
    check "copied $f" cmp -s "$R/system/$f" "$O/system/$f"
    check "manifest md5 for $f" grep -qx "ok $(md5sum "$R/system/$f" | cut -c1-32) system/$f" $M
done
check 'framework jar copied by glob' test -f $O/system/framework/services.jar
check 'missing file recorded' grep -qx 'missing - system/lib/libopus.so' $M
check 'symlinked source is not followed' grep -qx 'missing - system/lib/libCarPlayCore.so' $M
check 'no partial files left' eval '! ls $O/system/*/*.part >/dev/null 2>&1'
check 'completion toast' grep -q '원본 수집 완료' $W/calls

# PC verifier
check 'verifier accepts the dump' "$PY" -I "$S/verify.py" $O --sums $W/SHA256SUMS
check 'verifier writes SHA256SUMS' grep -q "$(sha256sum $R/system/app/HKMC_GPM.odex | cut -c1-64)  app/HKMC_GPM.odex" $W/SHA256SUMS
"$PY" -I "$S/verify.py" $O > $W/report.md 2>&1
check 'unregistered GPM is labelled' grep -q '`app/HKMC_GPM.odex` | 미등록' $W/report.md
{ echo verdict=block; echo "md5:app/HKMC_GPM.odex=$(md5sum $R/system/app/HKMC_GPM.odex | cut -c1-32)"; } > $W/CHECK.txt
check 'verifier accepts matching CHECK.txt' "$PY" -I "$S/verify.py" $O --check $W/CHECK.txt
echo 'md5:app/HKMC_DiPO.odex=00000000000000000000000000000000' >> $W/CHECK.txt
check 'verifier rejects CHECK.txt from a different state' eval '! "$PY" -I "$S/verify.py" $O --check $W/CHECK.txt >/dev/null'
echo tampered >> $O/system/app/HKMC_GPM.odex
check 'verifier rejects a corrupted copy' eval '! "$PY" -I "$S/verify.py" $O >/dev/null'

# copy that does not match the source is reported, not kept
printf '#!/bin/sh\ncase "$1" in *.part) echo ffffffffffffffffffffffffffffffff "$1";; *) md5sum "$1";; esac\n' > $W/bin/md5
check 'bad copy fails the run' eval '! run'
check 'bad copy recorded' grep -q '^copy-failed [0-9a-f]* system/app/HKMC_GPM.odex$' $M
check 'bad copy result incomplete' grep -qx 'result=incomplete' $M
check 'bad copy not kept' test ! -e $O/system/app/HKMC_GPM.odex
check 'bad copy part removed' test ! -e $O/system/app/HKMC_GPM.odex.part
printf '#!/bin/sh\nmd5sum "$1" 2>/dev/null || exit 1\n' > $W/bin/md5

# installer backups present: still copies, but flags it
mkdir -p $R/system/etc/gen5w-kr-backup; run
check 'records installer backup' grep -qx 'gen5w_backup=present' $M
check 'verifier warns about installer backup' eval '! "$PY" -I "$S/verify.py" $O >/dev/null'
rmdir $R/system/etc/gen5w-kr-backup

# refusals
rm -rf $O; ln -s $W $O
check 'symlinked output refused' eval '! run'
check 'symlinked output not followed' test ! -e $W/MANIFEST.txt
rm $O; echo 0 > $W/props/sys.boot_completed
check 'refuses before boot completes' eval '! run'
check 'nothing written before boot completes' test ! -e $O

check 'script never remounts or writes /system' eval '! grep -v "^#" "$S/NEMESIS.sh" | grep -nE "mount|setprop|> *\"?\\\$SYS|chmod|chown"'
done_tests stock-dump
