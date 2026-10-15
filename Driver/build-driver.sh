#!/bin/zsh
# Builds build/Vocalizer.driver (HAL AudioServerPlugIn). Install with scripts/install-driver.sh.
set -euo pipefail
cd "$(dirname "$0")"
python3 patch.py BlackHole.c VocalizerDriver.c >/dev/null
OUT=../build/Vocalizer.driver
rm -rf "$OUT"; mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun clang -isysroot /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk -O2 -bundle -arch arm64 -arch x86_64 -mmacosx-version-min=11.0 -w \
  -framework CoreAudio -framework CoreFoundation -framework Accelerate \
  -o "$OUT/Contents/MacOS/Vocalizer" VocalizerDriver.c
cp Info.plist "$OUT/Contents/Info.plist"
cp ../../vendor/BlackHole/BlackHole/BlackHole.icns "$OUT/Contents/Resources/Vocalizer.icns" 2>/dev/null || true
SIGN_ID=${SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')}
codesign --force --sign "${SIGN_ID:--}" "$OUT"
echo "built $OUT"
