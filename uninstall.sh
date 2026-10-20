#!/bin/bash
# Removes Vocalizer, its audio device and its settings.
#   curl -fsSL https://getvocalizer.com/uninstall.sh | bash
set -euo pipefail
APP="/Applications/Vocalizer.app"
DRIVER="/Library/Audio/Plug-Ins/HAL/Vocalizer.driver"
# Quitting gives the speakers back as the default output.
pkill -x Vocalizer 2>/dev/null && sleep 2 || true
CMD="rm -rf '$APP' '$DRIVER' && killall coreaudiod"
if [[ -d "$DRIVER" || ! -w /Applications ]]; then
  osascript -e "do shell script \"$CMD\" with administrator privileges with prompt \"Remove Vocalizer and its audio device.\"" >/dev/null
else
  rm -rf "$APP"
fi
rm -rf "$HOME/Library/Application Support/Vocalizer"
defaults delete com.0xarx.vocalizer-mac 2>/dev/null || true
tccutil reset AudioCapture com.0xarx.vocalizer-mac >/dev/null 2>&1 || true
echo "Vocalizer removed."
