#!/bin/zsh
# Builds libdf.dylib (DeepFilterNet3, MIT/Apache-2.0) for the optional Calls mode.
# Needs Rust (`brew install rust`). Output: .build/deepfilter/target/release/libdf.dylib
set -euo pipefail
cd "$(dirname "$0")/.."
COMMIT=d375b2d8309e0935d165700c91da9de862a99c31   # pinned, tested
DIR=.build/deepfilter
command -v cargo >/dev/null || { echo "Rust not found: brew install rust  (or skip Calls mode)"; exit 1; }
if [[ ! -d $DIR/.git ]]; then
  mkdir -p .build
  git clone -q https://github.com/Rikorose/DeepFilterNet.git $DIR
fi
git -C $DIR fetch -q --depth 1 origin $COMMIT 2>/dev/null || true
git -C $DIR checkout -q $COMMIT
(cd $DIR && cargo build --release -p deep_filter --no-default-features --features capi)
ls -la $DIR/target/release/libdf.dylib
