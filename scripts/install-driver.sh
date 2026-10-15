#!/bin/zsh
# Installs build/Vocalizer.driver into /Library/Audio/Plug-Ins/HAL and restarts Core Audio.
# Shows the standard macOS administrator password dialog. Uninstall: scripts/install-driver.sh --remove
set -euo pipefail
cd "$(dirname "$0")/.."
DEST=/Library/Audio/Plug-Ins/HAL/Vocalizer.driver
if [[ "${1:-}" == "--remove" ]]; then
  CMD="rm -rf '$DEST' && killall coreaudiod"
else
  CMD="rm -rf '$DEST' && cp -R '$PWD/build/Vocalizer.driver' '$DEST' && chown -R root:wheel '$DEST' && killall coreaudiod"
fi
osascript -e "do shell script \"$CMD\" with administrator privileges with prompt \"Vocalizer wants to install its audio device (keeps video in sync).\""
echo "done"
