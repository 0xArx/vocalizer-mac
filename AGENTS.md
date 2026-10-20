# AGENTS.md: Vocalizer for Mac

Instructions for coding agents (Claude Code, Codex, Cursor, Copilot, ...) asked to **install Vocalizer for a user**
or to **work on its code**. Humans: see [README.md](README.md).

Vocalizer is a macOS menu bar app that removes the music from any app's sound and keeps the voices. It captures
audio with Core Audio process taps, separates it on the Neural Engine (UVR MDX-Net, converted to Core ML), and plays
the vocals on the user's speakers. An optional virtual audio device ("Vocalizer") reports the processing delay so
video players hold the picture back and lips stay in sync.

## Install it for the user

### 1. Check the Mac (stop and tell the user if either fails)

```bash
uname -m              # must be arm64 (Apple silicon). Intel Macs are not supported.
sw_vers -productVersion   # must be 14.2 or later
```

### 2. Run the installer

```bash
curl -fsSL https://getvocalizer.com/install.sh | bash
```

It downloads the latest prebuilt release, copies `Vocalizer.app` to `/Applications`, installs the audio device to
`/Library/Audio/Plug-Ins/HAL/Vocalizer.driver`, restarts Core Audio, and opens the app. No compiler is needed.

Options (pass after `bash -s --`, e.g. `curl ... | bash -s -- --no-driver`):

| Option | Use when |
|---|---|
| `--no-driver` | the user does not want an audio device / no admin rights. Everything works except video sync. |
| `--from-source` | no release is available, or the user wants to build it. Needs `swift` (Xcode or `xcode-select --install`). |
| `--with-speech` | with `--from-source`: also build the optional Calls mode (needs Rust: `brew install rust`). |
| `--no-launch` | don't open the app afterwards. |

### 3. Things only the user can do (tell them, don't try to do them yourself)

1. **Admin password.** Installing the audio device shows the standard macOS password dialog. Ask the user to type
   their password there. Never ask for the password in chat and never type it.
2. **System Audio Recording permission.** The first time they switch Vocalizer on, macOS asks to allow
   *System Audio Recording*. They must click **Allow**. If they missed it: System Settings › Privacy & Security ›
   Screen & System Audio Recording › turn on **Vocalizer**.
3. **Switch it on.** Click the Vocalizer icon (a waveform in a circle) in the menu bar and flip the switch. Mode **Fast** is the default
   (modes in the menu: Fast, Clean, Best, Calls = `live`, `quality`, `supreme`, `ultra` in code).
   **Best** (~7 s delay hidden by video sync) needs a one-time 400 MB download: the user clicks **Download** in the
   menu, or run `/Applications/Vocalizer.app/Contents/MacOS/Vocalizer --download-supreme`.

### 4. Verify (optional)

```bash
pgrep -lf /Applications/Vocalizer.app                       # running
system_profiler SPAudioDataType | grep -A3 "Vocalizer:"     # audio device present
/Applications/Vocalizer.app/Contents/MacOS/Vocalizer --list  # apps currently producing audio
```

An end-to-end check that plays a file and measures the result (it plays sound for N seconds; the user's
Vocalizer must be switched off first because it refuses to run while the device is already the default output):

```bash
open -W -n /Applications/Vocalizer.app --args --selftest /path/to/song.wav 10 sync-live /tmp/vocalizer-test
cat /tmp/vocalizer-test/log.txt    # input/output levels, latency, underruns
```

The self-test must run inside the app bundle (via `open`): a bare command line process gets silence because only
app bundles can hold the System Audio Recording permission.

### 5. Uninstall

In Finder: right-click Vocalizer in Applications › **Services › Uninstall Vocalizer**, or drag it to the Bin (it offers to remove the rest). Or right-click the menu bar icon › **Uninstall Vocalizer…**. `VOCALIZER_UNINSTALL_DRYRUN=1` makes uninstall only log (for testing). Or from the Terminal:

```bash
curl -fsSL https://getvocalizer.com/uninstall.sh | bash
```

### Troubleshooting

| Symptom | Fix |
|---|---|
| No sound at all after quitting | Vocalizer restores the speakers when it quits; if it was killed hard, reopen it once, or pick the speakers in System Settings › Sound. |
| Switched on, but nothing changes / "No audio is coming in" | System Audio Recording permission is off (step 3.2). |
| Menu shows "Needs the Vocalizer audio device" | Re-run the installer, or click **Install…** in the menu. |
| Video slightly out of sync after changing modes | Pause and play the video once (players read the delay when they open the device). |
| Music not fully removed | Expected on heavy reverb / backing vocals. Try **Quality** mode. **Calls** mode is for calls and games (lowest delay), not videos. |

## Work on the code

```bash
git clone https://github.com/0xArx/vocalizer-mac && cd vocalizer-mac
scripts/build-app.sh            # -> build/Vocalizer.app   (--install also copies it to /Applications)
scripts/build-deepfilter.sh     # optional Calls mode (Rust)
Driver/build-driver.sh          # audio device -> build/Vocalizer.driver; scripts/install-driver.sh installs it
swift build -c release && .build/release/vocalizer-bench Models fixtures/musdb-fixture all presets  # offline quality/speed
```

Releases (maintainer only): bump `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist`, then
`scripts/publish.sh "one change per line"` does everything: build, Developer ID signing, notarization, the Sparkle
EdDSA signature (`.signing/sparkle-private.key`), the GitHub release, `website/appcast.xml`, and the deploy. Bump
`Driver/Info.plist` `CFBundleVersion` only when the driver changes (installed apps then offer to update it).
Under the hood `scripts/package-release.sh` signs with the Developer ID identity in the keychain
(hardened runtime, `Resources/Vocalizer.entitlements`), notarizes with the `vocalizer` notarytool keychain profile
(`scripts/notarize.sh`), staples, and writes `build/Vocalizer-macOS.zip`. Without a Developer ID it builds an
unnotarized zip and says so. `HARDENED=1 scripts/build-app.sh` tests the release signing with a development identity.

Layout:

| Path | What |
|---|---|
| `Sources/VocalizerCore/VocalizerEngine.swift` | tap + private aggregate device + real-time IO proc, lock-free rings, worker thread |
| `Sources/VocalizerCore/StreamingSeparator.swift` | sliding-window MDX separation, presets (live / balanced / quality) |
| `Sources/VocalizerCore/MDXSpectrogram.swift`, `MDXModel.swift` | STFT/iSTFT matching UVR, Core ML wrapper |
| `Sources/VocalizerCore/DeepFilterSeparator.swift` | Calls mode (DeepFilterNet3 via `libdf.dylib`, loaded at runtime) |
| `Sources/VocalizerCore/ProfanityFilter.swift`, `Sources/CRing/cmute.c` | swear-word filter: SpeechAnalyzer on the captured audio, mute events applied on the IO thread (no added delay); test with `tools/analyze_profanity.py` |
| `Sources/VocalizerCore/RoformerSeparator.swift`, `SupremeModel.swift` | Supreme mode (MelBand RoFormer on the GPU) and its on-demand download (`models-v1` release) |
| `Sources/VocalizerMac/Updater.swift`, `SelfInstaller.swift` | Sparkle finds updates; SelfInstaller installs them by swapping the whole bundle after checking the EdDSA signature (SUPublicEDKey) and the Developer ID team, because macOS App Management blocks writes inside a notarized app and Sparkle would ask for an admin password. Test hooks: `VOCALIZER_FEED_URL`, `VOCALIZER_UPDATE_NOW`, `VOCALIZER_TEST_CLICK_UPDATE` |
| `Sources/VocalizerCore/AudioProcesses.swift` | process list, devices, volume, the Vocalizer device's `'vlat'` latency property |
| `Sources/VocalizerMac/` | SwiftUI menu bar app (all UI text through `L()`; Arabic in `Resources/Localization/ar.lproj`, English text is the key); `main.swift` also has `--selftest`, `--sync-run`, `--snapshot`, `--list` |
| `Driver/` | `BlackHole.c` (GPL-3.0) + `patch.py` that turns it into the Vocalizer device |
| `Models/` | Core ML packages (32 / 64 / 256-frame windows); `tools/convert.py` regenerates them from ONNX |
| `tools/` | Python: model conversion, test fixtures (MUSDB18 samples), loopback analysis; `make-icon.swift` builds the app icon from `Resources/brand/logo.png` |
| `website/` | the static site at getvocalizer.com (Vercel project `vocalizer`; the old vocalizer-mac.vercel.app still serves it, including the appcast that 0.3.5–0.3.7 read); deploy with `npx vercel deploy --prod` from that folder. `website/ar/` is generated: edit the English pages, then `python3 tools/ar_site.py` |

Rules that matter:

- **Never block the IO thread** (`VocalizerEngine.io`): no locks, allocation, logging or Swift arrays that grow.
- **In sync mode the delay is fixed** for the whole run (`fixedDelay: true`) and reported once. Changing it while a
  video plays makes Chrome re-sync visibly (stutter). After a dropout the engine skips ahead instead.
- **Test audio changes inside the app bundle** (`--selftest`, `--sync-run`); a plain CLI receives silence.
- The app must restore the user's real speakers whenever it stops (off, quit, SIGTERM, relaunch). Keep that.
- Supreme's playback buffer must cover a whole model call (`recommendedJitterMs`), or every step underruns.
- A `--watchdog` child process restores the speakers if the app dies hard; keep it ignoring SIGTERM.
- Apple silicon only; macOS 14.2+.
