#!/bin/zsh
# Builds the release zip (app + audio device + Speech mode) for GitHub Releases.
#   scripts/package-release.sh   -> build/Vocalizer-macOS.zip
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -f .build/deepfilter/target/release/libdf.dylib || -f ../vendor/DeepFilterNet/target/release/libdf.dylib ]] \
  || scripts/build-deepfilter.sh
scripts/build-app.sh
rm -f build/Vocalizer-macOS.zip
ditto -c -k --norsrc --noextattr --keepParent build/Vocalizer.app build/Vocalizer-macOS.zip
shasum -a 256 build/Vocalizer-macOS.zip
ls -lh build/Vocalizer-macOS.zip
