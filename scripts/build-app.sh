#!/bin/zsh
# Builds build/Vocalizer.app: release binary, compiled Core ML models, Info.plist, code signature.
# Signs with the first Apple Development identity if there is one (keeps the System Audio
# Recording permission across rebuilds), otherwise ad hoc. Set SIGN_ID to override.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product VocalizerMac
APP=build/Vocalizer.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/VocalizerMac "$APP/Contents/MacOS/Vocalizer"
for f in 32 64 256; do
  if [[ ! -d Models/MDXVocals$f.mlmodelc ]]; then
    xcrun coremlcompiler compile Models/MDXVocals$f.mlpackage Models/ >/dev/null
  fi
  cp -R Models/MDXVocals$f.mlmodelc "$APP/Contents/Resources/"
done
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Sync-video driver (installed from the menu, or with scripts/install-driver.sh).
Driver/build-driver.sh >/dev/null
cp -R build/Vocalizer.driver "$APP/Contents/Resources/"
# Ultra fast mode: DeepFilterNet3 (libDF built with `cargo build --release -p deep_filter --features capi`).
DF=${DF_DIR:-../vendor/DeepFilterNet}
if [[ -f $DF/target/release/libdf.dylib ]]; then
  mkdir -p "$APP/Contents/Frameworks"
  cp $DF/target/release/libdf.dylib "$APP/Contents/Frameworks/"
  install_name_tool -id @rpath/libdf.dylib "$APP/Contents/Frameworks/libdf.dylib" 2>/dev/null || true
  cp $DF/models/DeepFilterNet3_onnx.tar.gz "$APP/Contents/Resources/"
fi
SIGN_ID=${SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')}
codesign --force --deep --sign "${SIGN_ID:--}" "$APP" 2>&1 | grep -v "replacing existing signature" || true
codesign -dv "$APP" 2>&1 | grep -E "Identifier|Authority=Apple Development|Signature=adhoc" || true
echo "built $APP"
# --install: copy this build over /Applications/Vocalizer.app.
if [[ "${1:-}" == "--install" ]]; then
  pkill -x Vocalizer 2>/dev/null && sleep 1 || true
  ditto "$APP" /Applications/Vocalizer.app
  echo "installed /Applications/Vocalizer.app"
fi
