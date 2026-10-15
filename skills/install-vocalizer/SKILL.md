---
name: install-vocalizer
description: Install, verify or uninstall Vocalizer for Mac (github.com/0xArx/vocalizer-mac), a menu bar app that removes music from any app's audio system-wide and keeps the voices, with video kept in sync. Use when the user asks to install Vocalizer, remove music/background music from their Mac's audio, or set up vocal-only playback system-wide.
---

# Install Vocalizer for Mac

Full instructions live in the repo's AGENTS.md: https://github.com/0xArx/vocalizer-mac/blob/main/AGENTS.md
Short version:

1. **Check:** `uname -m` is `arm64` and `sw_vers -productVersion` is 14.2 or later. Otherwise stop: unsupported.
2. **Install:**
   ```bash
   curl -fsSL https://raw.githubusercontent.com/0xArx/vocalizer-mac/main/install.sh | bash
   ```
   Add `bash -s -- --no-driver` to skip the audio device (no video sync), or `--from-source` to build locally.
3. **Tell the user** (these need them, not you):
   - type their Mac password in the macOS dialog that installs the audio device (never ask for it in chat);
   - click **Allow** when macOS asks for *System Audio Recording* the first time they switch it on;
   - click the microphone icon in the menu bar and flip the switch (Live mode is the default).
4. **Verify:** `pgrep -lf /Applications/Vocalizer.app` and `system_profiler SPAudioDataType | grep -A3 "Vocalizer:"`.
5. **Uninstall:** `curl -fsSL https://raw.githubusercontent.com/0xArx/vocalizer-mac/main/uninstall.sh | bash`

Copy this folder to `~/.claude/skills/` (or your agent's skills folder) to make it available everywhere.
