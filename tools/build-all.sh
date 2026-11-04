#!/bin/bash
# Builds everything into dist/: package zips and ready-to-copy USB folders.
set -euo pipefail
cd "$(dirname "$0")/.."
# Binary revision and source archive must describe the code being compiled.
if ! git diff --quiet || ! git diff --cached --quiet || [ -n "$(git ls-files --others --exclude-standard)" ]; then
    echo 'Release build requires a clean committed source checkout.' >&2
    exit 1
fi
PY=$(command -v python3 || command -v python)
SDK=${ANDROID_SDK:-${ANDROID_HOME:-$HOME/AppData/Local/Android/Sdk}}
NDK=${ANDROID_NDK_HOME:-$SDK/ndk/27.2.12479018}
rm -rf dist; mkdir -p dist
bash probe/build.sh
mkdir -p probe/package/app
cp probe/build/gen5w-probe.apk probe/package/app/gen5w-probe.apk
"$PY" -I tools/mkpkg.py probe/package dist/gen5w.kr.probe.zip

"$PY" -I tools/mkpkg.py packages/wireless-enable dist/gen5w.kr.wireless.zip

"$PY" -I tools/audio/build.py --ndk "$NDK"
"$PY" -I tools/mkpkg.py packages/audio-format dist/gen5w.kr.audio.zip
"$PY" -I tools/iap2/build.py --ndk "$NDK"
bash tools/build-dex.sh packages/wireless-bridge kr.gen5w.wireless.WirelessBridge bridge.dex
bash tools/build-wireless-host.sh
"$PY" -I tools/mkpkg.py packages/wireless-bridge dist/gen5w.kr.bridge.zip

# HUD core and stock-warning timer, then the public USB bundles.
bash app/build.sh
mkdir -p packages/core/app
cp app/build/gen5w-core.apk packages/core/app/gen5w-core.apk
"$PY" -I tools/mkpkg.py packages/core dist/gen5w.kr.core.zip
# Service-only close; carries a SHA-256 checker (verify mode only) for the stock SystemUI check.
mkdir -p packages/consent-timer/bin
cp packages/audio-format/bin/audio-patch packages/consent-timer/bin/sha256-check
"$PY" -I tools/mkpkg.py packages/consent-timer dist/gen5w.kr.timer.zip

# Bluelink monthly reminder hider (service only, part of standard and dongle).
"$PY" -I tools/mkpkg.py packages/bluelink-quiet dist/gen5w.kr.bluelink.zip

# Optional numeric-only driving log; standalone so it does not require either APK.
"$PY" -I tools/mkpkg.py packages/drive-log dist/gen5w.kr.drivelog.zip

# USB Wi-Fi dongle package (stock Wi-Fi HAL unchanged; bcmdhd stand-in module)
"$PY" -I tools/usb-wifi/build_dongle_zip.py

"$PY" -I tools/integrated/build.py --dist dist --output dist/usb-integrated
"$PY" -I tools/integrated/build.py --skip-native --variant standard --dist dist --output dist/gen5w-kr-standard
"$PY" -I tools/integrated/build.py --skip-native --variant dongle --dist dist --output dist/gen5w-kr-dongle
"$PY" -I tools/integrated/build.py --skip-native --variant safe --dist dist --output dist/gen5w-kr-safe
"$PY" -I tools/integrated/build.py --skip-native --variant safe-wireless --dist dist --output dist/gen5w-kr-safe-wireless
"$PY" -I tools/integrated/build.py --skip-native --variant check --dist dist --output dist/gen5w-kr-check

# USB folders: copy the contents of one of these to the root of a USB drive
mkdir -p dist/usb-probe-install/packages dist/usb-probe-collect dist/usb-detect dist/usb-stock-dump
cp probe/usb/install/NEMESIS.data dist/usb-probe-install/
cp dist/gen5w.kr.probe.zip dist/usb-probe-install/packages/
cp probe/usb/collect/NEMESIS.data probe/usb/collect/NEMESIS.sh dist/usb-probe-collect/
cp tools/usb-detect/NEMESIS.data tools/usb-detect/NEMESIS.sh dist/usb-detect/
cp tools/stock-dump/NEMESIS.data tools/stock-dump/NEMESIS.sh dist/usb-stock-dump/
git archive --format=zip --prefix=gen5w-kr-source/ -o dist/gen5w-kr-source.zip HEAD
(cd dist && for z in *.zip; do md5sum "$z"; done) | tee dist/MD5SUMS
(cd dist && for z in *.zip; do sha256sum "$z"; done) > dist/SHA256SUMS
