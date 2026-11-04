#!/bin/bash
# Boot-loop self-recovery on a K8 GL3 HEV unit: only the v039gl3 helpers
# recognise its files, the reference-vehicle helpers reject them.
. "$(dirname "$0")/lib.sh"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
W=$(mktemp -d)
SYS="$W/system"; DATA="$W/data"; CACHE="$W/cache"; BG="$DATA/nemesis/gen5wkr.bootguard"
mkdir -p "$SYS/framework" "$SYS/priv-app" "$SYS/app" "$SYS/lib" \
    "$SYS/etc/gen5w-kr-backup/bridge" "$SYS/etc/gen5w-kr-backup/audio" \
    "$BG" "$CACHE/dalvik-cache" "$W/bin"
printf '#!/bin/sh\necho "nemesis $*" >> "$BG_TEST_DATA/calls"\nexit 0\n' > "$W/nemesis"
chmod +x "$W/nemesis"
helper() { # helper ID NAME PREFIX: original/patched recognise "<PREFIX>stock-"/"<PREFIX>patched-"
    mkdir -p "$DATA/nemesis/apps/$1/bin"
    printf '#!/bin/sh\ncase "$1" in original) grep -q "^%sstock-" "$2";; patched) grep -q "^%spatched-" "$2";; *) exit 1;; esac\n' "$3" "$3" \
        > "$DATA/nemesis/apps/$1/bin/$2"
    chmod +x "$DATA/nemesis/apps/$1/bin/$2"
}
for v in v039 v035; do
    for k in iap2-route iap2 dipo gpm; do helper gen5w.kr.bridge $k-patch-$v ref; done
done
helper gen5w.kr.audio audio-patch ref
helper gen5w.kr.audio audio-patch-v035 ref
recover() {
    BG_TEST_SYS="$SYS" BG_TEST_DATA="$DATA" BG_TEST_NEM="$W/nemesis" BG_TEST_DALVIK="$CACHE/dalvik-cache" \
        mksh "$ROOT/packages/wireless-bridge/scripts/bootguard-recover.sh" > "$W/out" 2>&1
}
setup() {
    local backup target
    for pair in bridge/original:app/Iap2ServerApp.odex bridge/dipooriginal:app/HKMC_DiPO.odex \
                bridge/gpmoriginal:app/HKMC_GPM.odex audio/original:lib/libCarPlayAudio.so; do
        backup=$SYS/etc/gen5w-kr-backup/${pair%%:*}; target=$SYS/${pair#*:}
        printf 'gl3stock-%s\n' "$target" > "$backup"
        printf 'gl3patched-%s\n' "$target" > "$target"
    done
    rm -f "$BG/recovered" "$BG/recovery-required"
    printf 0 > "$BG/count"; printf 3 > "$BG/max"; printf armed > "$BG/armed"
}

# Without the GL3 helpers nothing recognises the files: fail closed, change nothing.
setup
check 'GL3 files without GL3 helpers are refused' eval '! recover'
check 'refusal leaves the patched ODEX in place' grep -q '^gl3patched-' "$SYS/app/Iap2ServerApp.odex"
check 'refusal asks for manual recovery' test -f "$BG/recovery-required"

for k in iap2-route iap2 dipo gpm; do helper gen5w.kr.bridge $k-patch-v039gl3 gl3; done
helper gen5w.kr.audio audio-patch-v039gl3 gl3
setup
check 'GL3 recovery succeeds with GL3 helpers' recover
for pair in bridge/original:app/Iap2ServerApp.odex bridge/dipooriginal:app/HKMC_DiPO.odex \
            bridge/gpmoriginal:app/HKMC_GPM.odex audio/original:lib/libCarPlayAudio.so; do
    check "GL3 restores ${pair#*:}" cmp -s "$SYS/etc/gen5w-kr-backup/${pair%%:*}" "$SYS/${pair#*:}"
done
check 'GL3 recovery records success' grep -qx 'recovered rc=0' "$BG/recovered"

# A GL3 backup paired with a reference-vehicle live file is not one profile: refuse.
setup
printf 'refpatched-x\n' > "$SYS/app/HKMC_DiPO.odex"
check 'mixed-profile DiPO pair is refused' eval '! recover'
check 'mixed-profile refusal changes nothing' grep -q '^gl3patched-' "$SYS/app/Iap2ServerApp.odex"

# Audio not installed: the retained GL3 verifier must prove the live library is stock.
setup
rm -rf "$SYS/etc/gen5w-kr-backup/audio" "$DATA/nemesis/apps/gen5w.kr.audio"
printf 'gl3stock-lib\n' > "$SYS/lib/libCarPlayAudio.so"
mkdir -p "$BG/verifiers"
printf '#!/bin/sh\n[ "$1" = original ] && grep -q "^gl3stock-" "$2"\n' > "$BG/verifiers/audio-v039gl3"
chmod +x "$BG/verifiers/audio-v039gl3"
md5sum "$BG/verifiers/audio-v039gl3" | cut -d ' ' -f 1 > "$BG/verifiers/audio-v039gl3.md5"
check 'retained GL3 audio verifier accepts stock library' recover
check 'bridge restored alongside verified GL3 audio' cmp -s "$SYS/etc/gen5w-kr-backup/bridge/original" "$SYS/app/Iap2ServerApp.odex"
setup; rm -rf "$SYS/etc/gen5w-kr-backup/audio"; printf 'gl3stock-lib\n' > "$SYS/lib/libCarPlayAudio.so"
printf 'tampered\n' >> "$BG/verifiers/audio-v039gl3"
check 'tampered GL3 audio verifier is refused' eval '! recover'
rm -rf "$W"
done_tests bootguard-gl3
