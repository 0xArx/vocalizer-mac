# Vocalizer for Mac (prototype)

A menu bar app that removes the music from any app's sound, system wide, and keeps the voices.
It taps the app's audio with a Core Audio process tap (which also mutes the app), separates it with the
UVR MDX-Net vocal model on the Neural Engine, and plays the vocals to your output device.
Nothing leaves the Mac.

![menu](docs-menu.png)

## Build and run

Needs macOS 14.2+ on Apple silicon, Xcode command line tools, Swift 5.10+.

```bash
scripts/build-app.sh --install   # builds build/Vocalizer.app and copies it to /Applications
open /Applications/Vocalizer.app
```

Apple silicon only (by choice; Intel is not built). **Open at login** is in the menu, and the on/off state is
remembered across restarts.

The first time it taps audio, macOS asks for **System Audio Recording** permission
(System Settings › Privacy & Security › Screen & System Audio Recording). The app shows a warning if no audio
arrives. The Core ML models are already in `Models/`; to rebuild them from the ONNX file see "Models" below.

In the menu: switch it on, pick a **Mode**, optionally **Karaoke** to keep the music and drop the voices.
The status shows the latency, speed and levels.

**Keep video in sync** (on by default once the Vocalizer audio device is installed): all audio is routed
through a virtual output device called *Vocalizer*, which reports Vocalizer's real delay as its output latency.
Video players (Chrome/YouTube, Safari, QuickTime, ...) then hold the picture back by that delay, so lips match
the voice in every mode, even Quality. Your speakers stay the real output; switching to headphones in Sound
settings is picked up automatically, and the speakers are restored when you switch it off or quit.
The device is installed from the menu (**Install…**, asks for your admin password once) or with
`scripts/install-driver.sh` (`--remove` to uninstall). With sync off, the **Source** picker taps one app
(or all audio) directly and video runs ahead of the voice by the delay.

| Mode | Model | Delay (measured, end to end) | Best for |
|---|---|---|---|
| **Speech** (ultra fast) | DeepFilterNet3 (CPU) | **86 ms** | speech: talks, vlogs, calls. Weak on singing |
| **Live** | MDX-Net, 0.74 s window | 295 ms (tap) / 394 ms (sync, extra buffer) | videos with music and singing |
| **Balanced** | MDX-Net, 1.5 s window | 348 ms | a little cleaner |
| **Quality** | MDX-Net, 5.9 s window | 1.9 s | music apps, or any video with sync on |

## How it works

```
Apple Music / Safari / Chrome / Spotify ...
        │ (muted by the tap)
        ▼
CATapDescription(stereoMixdownOfProcesses:) ──▶ private aggregate device ◀── default output device (clock master)
                                                     │ IOProc (real time, lock-free rings)
                       inRing ◀──────────────────────┤──────────────────────▶ outRing (primed with step + jitter)
                         │                                                          ▲
   worker thread: 48 kHz → 44.1 kHz → STFT (vDSP) → MDX-Net (Core ML, Neural Engine) → iSTFT → 44.1 → 48 kHz
```

- **One clock.** The tap and the output device live in the same private aggregate device, so input and output
  never drift and one IOProc both reads the tap and writes the vocals.
- **Helpers are grouped.** Chrome plays through "Google Chrome Helper", Safari through `com.apple.WebKit.GPU`.
  The picker groups every Core Audio process under its responsible app, so picking "Chrome" taps all of them.
  *All audio* is a global tap that excludes Vocalizer itself.
- **Sliding window instead of look-ahead.** Live audio has no future to read, so every `step` the model runs on the
  latest window and keeps a segment that ends `rightContext` before the window's valid edge. Segments crossfade.
  Delay = `trim (87 ms) + rightContext + step` + jitter buffer + IO. See `StreamingSeparator.swift`.
- **The network is convolutional in time** (its MatMuls act on frequency), so the ONNX model converts to Core ML at
  any window that is a multiple of 32 frames. Windows of 32, 64 and 256 frames ship (0.74 s, 1.5 s, 5.9 s).

## Measured

MacBook (Apple silicon), macOS 27.0.1, output through a 48 kHz USB device. Model in fp16 on the Neural Engine
(Core ML output vs the ONNX fp32 model: 42–45 dB SNR).

### Model speed per call (Core ML)

| Window | Audio covered | Neural Engine | GPU | 
|---|---|---|---|
| 256 frames | 5.94 s | **99 ms** (60× real time) | 313 ms |
| 64 frames | 1.49 s | **24–31 ms** | 80 ms |
| 32 frames | 0.74 s | **12 ms** | 42 ms |

The browser extension's WebGPU path took about 1.2 s per 256-frame chunk; the Neural Engine is about 12× faster.

### Quality vs delay (offline benchmark, same audio for every row)

MUSDB18 sample set, 16 test excerpts with singing (109 s), SDR of our vocals against the true vocal stem.
"Doing nothing" (the mix itself) scores −3.8 dB.

| Mode | Window / step / future context | Algorithmic delay | SDR (all) | SDR (median song) | Compute (RTF) |
|---|---|---|---|---|---|
| Offline-like (reference) | 256 / 1 s / 2.4 s | 3.5 s | 10.39 dB | 11.16 dB | 0.12 |
| **Quality** | 256 / 1 s / 0.5 s | **1.59 s** | 10.38 dB | 10.96 dB | 0.12 |
| **Balanced** | 64 / 93 ms / 70 ms | **250 ms** | 10.10 dB | 10.89 dB | 0.33 |
| **Live** | 32 / 46 ms / 23 ms | **157 ms** | 9.80 dB | 10.39 dB | 0.37 |
| 32 / 46 ms / 12 ms | | 145 ms | 9.77 dB | 10.35 dB | 0.35 |

Going from 3.5 s to 157 ms of delay costs about 0.6 dB. The model barely needs future context, which is why a
live mode works at all. (Synthetic speech over synth music: 20 dB offline, 19 dB Live.)

### Real system path (loopback test inside the app)

`afplay` plays the MUSDB excerpts; the app taps it (muted), and two extra unmuted taps on the same aggregate
device record the original and Vocalizer's output, so the delay is measured sample-exactly by cross-correlation.

| Mode | Measured delay (tap in → our output) | Engine estimate | SDR vs true vocals | Compute (RTF) | Underruns |
|---|---|---|---|---|---|
| Live | 255 ms | 250 ms | 10.75 dB | 0.54–0.60 | 0 |
| Balanced | 348 ms | 343 ms | 11.23 dB | 0.48 | 0 |
| Quality | 1876 ms | 1870 ms | 11.67 dB | 0.16 | 0 |

(Each run covers a different 12–13 s stretch of songs, so compare SDR across modes with the offline table above.)
Delay = algorithmic delay + one step of buffering + 60 ms jitter buffer (250 ms in Quality) + ~25 ms IO.

The engine's own latency estimate is within a few ms of the measured value, so the menu's number is trustworthy.
Add the output device's own latency (13 ms on this USB device; Bluetooth headphones add 150–250 ms more).
No underruns in any run.

### Apple Music (DRM)

**Apple Music streaming (FairPlay) is capturable.** With an Apple Music catalog track playing, the tap on
`com.apple.Music` delivered the real signal (RMS 0.07–0.18), the app was muted, and separated vocals played.
Tested on streamed catalog tracks; no Apple Music downloads were on this Mac, but they decode in the same process.
(Video DRM in Safari, e.g. Netflix, was not tested.)

### Video sync (virtual device)

`Driver/` builds `Vocalizer.driver`, an AudioServerPlugIn made from BlackHole's loopback driver
(GPL-3.0, `Driver/LICENSE-BlackHole`; `Driver/patch.py` renames it and adds a custom `'vlat'` property that sets
the device's output latency). The app taps everything sent to the device (a device tap, so no microphone
permission is needed) and plays the vocals on the real output through the same aggregate device as before.

- Sync path, Live mode: measured 394 ms delay vs 390 ms estimated, 10.6 dB SDR, no dropouts.
- Chromium sees the reported delay: `AudioContext.outputLatency` is **408 ms** through the Vocalizer device
  set to 400 ms, vs 16 ms on the USB speakers. Chrome paces video by the same output delay. Safari/AVFoundation
  also honour device latency (standard behaviour; not separately measured here).
- **The delay is fixed while playing.** It is reported once per start and the engine holds playback exactly at it:
  after a rare dropout it skips ahead rather than growing the buffer, and it never re-reports. An earlier build
  updated the delay after dropouts and could restart itself on its own output switches; each change made the video
  visibly re-sync (stutter and catch-up).
- Measured in real Chrome with the app running (sync, Live): 361 frames in 12 s at 30 fps, 0 freezes, 0 skipped,
  0 dropped; `outputLatency` steady at 416 ms; one engine start, 0 underruns over the run.
- Apps read the latency when they open the device, so a mode change briefly switches the default output away and
  back to make them re-read it (one re-sync). If a video still looks off after switching modes, pause and play it.

### Ultra fast (DeepFilterNet3)

A speech enhancement model (github.com/Rikorose/DeepFilterNet, MIT/Apache-2.0) that treats music as noise:
48 kHz, 10 ms frames, 2 frames of look-ahead (31 ms algorithmic), about 4.5 ms of CPU per 10 ms frame for stereo.
Built from source with `cargo build --release -p deep_filter --no-default-features --features capi` (Rust from Homebrew);
`scripts/build-app.sh` bundles `libdf.dylib` and the model when `../vendor/DeepFilterNet` exists.

| Same audio as above | Delay | SDR |
|---|---|---|
| Speech over synthetic music | 31 ms | 9.5 dB (MDX Live: 19.0) |
| Real songs (MUSDB18) | 31 ms | 1.2 dB (MDX Live: 9.8; doing nothing: −3.8) |

So Ultra is for spoken content; for singing use Live (or Quality with sync on).

## Where it works

Tested on this Mac (MacBook Air, USB speakers + built-in speakers):

| | |
|---|---|
| Apple Music (FairPlay streams) | ✅ captured and separated |
| Video in Chrome, sync on | ✅ 30 fps, 0 dropped frames, delay steady (416 ms) |
| Apps pinned to a specific speaker | ✅ caught (sync mode uses a global tap); vocals play on your chosen speakers |
| Volume keys / mute, sync on | ✅ passed through to the real speakers (software gain if they have no volume control) |
| Switching speakers while playing | ✅ follows (USB ↔ built-in), no dropouts |
| Speakers unplugged | moves to the next output (logic tested by switching; not physically unplugged) |
| Force quit / crash | ✅ speakers restored as the default output (signal handler + check at launch) |
| Mono or multichannel outputs | uses the device's preferred stereo pair, mono gets (L+R)/2 (stereo verified; others by code) |
| Sleep / wake | restarts the pipeline on wake (not tested here) |

Not tested: AirPlay outputs (none available), Netflix/Disney+ in Safari, Firefox video sync.
Delay can't be hidden from calls and games (use Speech mode, ~0.15 s with sync on).

## Limits found

- **Delay is unavoidable, but hidden with sync on.** Without the virtual device, Live is about 0.3 s behind the source
  and lips visibly lead the voice. With **Keep video in sync**, players delay the picture to match.
  Things that cannot be delayed (games, live calls) still hear the delay; use Ultra for those.
- **Small pops (fixed).** The Neural Engine occasionally takes 100–175 ms for a 20 ms call. The output buffer now
  grows by 40 ms after any dropout and fades out/in around it, so it settles without clicks; Live starts with a
  100 ms buffer (sync mode 200 ms, hidden from video).
- **Quality on real songs is ~10–11 dB SDR**, the same as the offline model: reverb tails, backing vocals and some
  synths leak through; heavily processed vocals can lose some body. The model's weak right edge costs well under 1 dB
  in Live mode.
- **Neural Engine timing is spikier when called often.** In the app, 32-frame calls take ~20 ms instead of 12 ms
  (the ANE seems to idle between 46 ms steps), so Live runs at RTF ~0.55. Still under 1 with headroom; the 60 ms
  jitter buffer absorbs spikes.
- **System Audio Recording permission** is required and only granted to app bundles; a bare command line tool
  receives silence. Re-signing with a different identity asks again.
- **Output device changes** restart the pipeline (a short gap). Sample-rate changes on the fly are not handled
  beyond that restart.
- *All audio* also captures system sounds and notifications and runs them through the model.
- System volume applies to Vocalizer's output as normal.
- Not notarized; it is a local prototype.

## Files

| | |
|---|---|
| `Sources/VocalizerCore/MDXSpectrogram.swift` | STFT/iSTFT matching UVR (port of the extension's `mdx.js`, vDSP DFT of 7680 = 15·512) |
| `Sources/VocalizerCore/MDXModel.swift` | Core ML wrapper (strided output, Neural Engine) |
| `Sources/VocalizerCore/StreamingSeparator.swift` | sliding-window separation and the three presets |
| `Sources/VocalizerCore/VocalizerEngine.swift` | process tap, aggregate device, IOProc, rings, worker thread, stats |
| `Sources/VocalizerCore/AudioProcesses.swift` | Core Audio process list grouped by responsible app |
| `Sources/VocalizerCore/LoopbackTest.swift` | end-to-end test (run inside the app: `--selftest`) |
| `Sources/VocalizerMac/` | SwiftUI menu bar app (`--list`, `--selftest`, `--snapshot` for testing) |
| `Sources/vocalizer-bench/` | offline benchmark: SDR, latency, speed per config |
| `tools/` | model conversion, fixtures, loopback analysis (Python venv) |

## Tests and tools

```bash
# Python tools (conversion + fixtures + analysis)
python3.11 -m venv tools/.venv && tools/.venv/bin/pip install onnx onnx2torch torch coremltools numpy onnxruntime musdb

# Models: ONNX -> Core ML (window sizes as arguments)
tools/.venv/bin/python tools/convert.py ../vocalizer/extension/models/mdx-vocals.onnx Models 256 64 32

# Fixtures: synthetic (say + synth music) and real music (MUSDB18 7 s samples, 140 MB download)
tools/.venv/bin/python tools/make_fixture.py fixtures
tools/.venv/bin/python tools/make_musdb_fixture.py fixtures

# Offline benchmark (presets, or the full sweep), optionally on cpu|gpu|ane|all
swift build -c release && .build/release/vocalizer-bench Models fixtures/musdb-fixture all presets

# End-to-end loopback through the real system path (plays audio out loud for N seconds)
ffmpeg -f f32le -ar 44100 -ac 2 -i fixtures/musdb-fixture/mix.f32 -t 60 fixtures/musdb-mix.wav
open -W -n build/Vocalizer.app --args --selftest $PWD/fixtures/musdb-mix.wav 16 live $PWD/fixtures/app-live
tools/.venv/bin/python tools/analyze_loopback.py fixtures/app-live fixtures/musdb-fixture

# Tap a running app instead of afplay
open -W -n build/Vocalizer.app --args --selftest app:com.apple.Music 12 live $PWD/fixtures/app-music
```
