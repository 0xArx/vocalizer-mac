#!/bin/zsh
# Builds build/Vocalizer.driver (HAL AudioServerPlugIn). Install with scripts/install-driver.sh.
set -euo pipefail
cd "$(dirname "$0")"
python3 patch.py BlackHole.c VocalizerDriver.c >/dev/null
# Prefer full Xcode when installed (its SDK and linker always match).
if [[ -d /Applications/Xcode.app ]]; then export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}; fi
SDK=$(xcrun --sdk macosx --show-sdk-path)
OUT=../build/Vocalizer.driver
rm -rf "$OUT"; mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
xcrun clang -isysroot "$SDK" -O2 -bundle -arch arm64 -mmacosx-version-min=14.2 -w \
  -framework CoreAudio -framework CoreFoundation -framework Accelerate \
  -o "$OUT/Contents/MacOS/Vocalizer" VocalizerDriver.c
cp Info.plist "$OUT/Contents/Info.plist"
cp ../Resources/AppIcon.icns "$OUT/Contents/Resources/Vocalizer.icns"
ids=$(security find-identity -v -p codesigning 2>/dev/null)
SIGN_ID=${SIGN_ID:-$(awk -F'"' '/Developer ID Application/ {print $2; exit}' <<<"$ids")}
SIGN_ID=${SIGN_ID:-$(awk -F'"' '/Apple Development/ {print $2; exit}' <<<"$ids")}
if [[ ${SIGN_ID:--} == "Developer ID"* ]]; then
  codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$OUT"
else
  codesign --force --sign "${SIGN_ID:--}" "$OUT"
fi
echo "built $OUT"
