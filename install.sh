#!/bin/bash
# Vocalizer installer: removes music from any app on your Mac and keeps the voices.
#
#   curl -fsSL https://raw.githubusercontent.com/0xArx/vocalizer-mac/main/install.sh | bash
#
# Options (after `bash -s --` when piping):
#   --from-source   build from source instead of downloading the prebuilt app (needs Xcode or its command line tools)
#   --with-speech   with --from-source: also build the optional Calls mode (needs Rust: brew install rust)
#   --no-driver     skip the Vocalizer audio device (no video sync; everything else works)
#   --no-launch     don't open the app at the end
#   --zip PATH      install from a local release zip (testing)
# Non-interactive: the only prompt is the standard macOS administrator dialog for the audio device.
set -euo pipefail

REPO="0xArx/vocalizer-mac"
APP_DEST="/Applications/Vocalizer.app"
DRIVER_DEST="/Library/Audio/Plug-Ins/HAL/Vocalizer.driver"
FROM_SOURCE=0; WITH_SPEECH=0; DRIVER=1; LAUNCH=1; ZIP=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from-source) FROM_SOURCE=1 ;;
    --with-speech) WITH_SPEECH=1 ;;
    --no-driver) DRIVER=0 ;;
    --no-launch) LAUNCH=0 ;;
    --zip) ZIP="$2"; shift ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "unknown option $1"; exit 2 ;;
  esac
  shift
done

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# Requirements: Apple silicon, macOS 14.2+ (Core Audio process taps).
[[ "$(uname -s)" == "Darwin" ]] || die "Vocalizer is a macOS app."
[[ "$(uname -m)" == "arm64" ]] || die "Vocalizer needs an Apple silicon Mac (M1 or later)."
OS=$(sw_vers -productVersion)
IFS=. read -r MAJ MIN _ <<<"$OS"
if (( MAJ < 14 || (MAJ == 14 && ${MIN:-0} < 2) )); then die "Vocalizer needs macOS 14.2 or later (this Mac has $OS)."; fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/vocalizer.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

if [[ $FROM_SOURCE == 1 ]]; then
  command -v swift >/dev/null || die "Swift not found. Install Xcode, or run: xcode-select --install"
  say "Downloading the source"
  git clone -q --depth 1 "https://github.com/$REPO.git" "$WORK/src"
  if [[ $WITH_SPEECH == 1 ]]; then
    say "Building Calls mode (DeepFilterNet, a few minutes the first time)"
    "$WORK/src/scripts/build-deepfilter.sh"
  fi
  say "Building Vocalizer (a minute or two)"
  "$WORK/src/scripts/build-app.sh" >/dev/null
  APP_SRC="$WORK/src/build/Vocalizer.app"
else
  if [[ -z "$ZIP" ]]; then
    say "Downloading the latest Vocalizer release"
    URL=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
      | grep -o '"browser_download_url": *"[^"]*Vocalizer-macOS\.zip"' | head -1 | sed 's/.*"\(https[^"]*\)"/\1/')
    [[ -n "$URL" ]] || die "No release found. Try: bash install.sh --from-source"
    ZIP="$WORK/Vocalizer-macOS.zip"
    curl -fsSL "$URL" -o "$ZIP"
  fi
  ditto -x -k "$ZIP" "$WORK/unzipped"
  APP_SRC="$WORK/unzipped/Vocalizer.app"
fi
[[ -d "$APP_SRC" ]] || die "Vocalizer.app missing from the download."

say "Installing to $APP_DEST"
pkill -x Vocalizer 2>/dev/null && sleep 1 || true   # it restores your speakers when it quits
if [[ -w /Applications ]]; then
  rm -rf "$APP_DEST"; ditto "$APP_SRC" "$APP_DEST"
else
  osascript -e "do shell script \"rm -rf '$APP_DEST' && ditto '$APP_SRC' '$APP_DEST'\" with administrator privileges" >/dev/null
fi
xattr -dr com.apple.quarantine "$APP_DEST" 2>/dev/null || true

if [[ $DRIVER == 1 ]]; then
  NEW="$APP_DEST/Contents/Resources/Vocalizer.driver"
  if [[ -d "$DRIVER_DEST" ]] && cmp -s "$NEW/Contents/MacOS/Vocalizer" "$DRIVER_DEST/Contents/MacOS/Vocalizer"; then
    say "Vocalizer audio device already installed"
  else
    say "Installing the Vocalizer audio device (keeps video in sync). macOS will ask for your password."
    osascript -e "do shell script \"rm -rf '$DRIVER_DEST' && ditto '$NEW' '$DRIVER_DEST' && chown -R root:wheel '$DRIVER_DEST' && killall coreaudiod\" with administrator privileges with prompt \"Vocalizer wants to install its audio device so video stays in sync.\"" >/dev/null \
      || die "Audio device not installed (password dialog cancelled). Re-run, or use --no-driver."
    sleep 2
  fi
fi

say "Installed. Vocalizer lives in the menu bar (a waveform in a circle)."
echo "    First time you switch it on, macOS asks to allow System Audio Recording: click Allow."
echo "    Uninstall: curl -fsSL https://raw.githubusercontent.com/$REPO/main/uninstall.sh | bash"
[[ $LAUNCH == 1 ]] && open "$APP_DEST"
exit 0
