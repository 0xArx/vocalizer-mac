# Builds a swear-word test clip with EXACT word boundaries: each phrase and each swear word is spoken
# separately by macOS `say`, trimmed to its sound, and joined with short gaps, so we know to the sample where
# every swear word starts and ends (the recognizer's own times are too rough to judge precision).
# Then it mixes music under the voice.
#   python3 tools/make_swear_fixture.py <music.wav> <out dir>
#   -> <out>/clip.wav (48 kHz mono) and <out>/words.json [{word, start, end}] for analyze_profanity.py
import json, os, subprocess, sys, tempfile
import numpy as np

music_path, out = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)
RATE, VOICE = 48000, "Samantha"
LEAD = 3.0        # silence before the speech (the engine and recognizer settle)
WORD_GAP = 0.05   # between words inside a sentence: neighbours are close, so over-wide mutes show up
SENT_GAP = 0.45

# Sentences as segments; *word* marks a swear word.
SENTENCES = [
    "Okay listen, this is *fucking* ridiculous and I mean it.",
    "What the *hell* were you thinking about yesterday?",
    "That whole story was total *bullshit* from the start.",
    "Well *damn*, I did not see that coming at all.",
    "Oh *shit*, we are going to be late again.",
    "He is such a *bastard* when he loses at cards.",
    "Stop being an *asshole* and help me carry this.",
    "This *crap* keeps breaking every single week.",
]

def speak(text):
    with tempfile.TemporaryDirectory() as d:
        aiff = os.path.join(d, "s.aiff")
        subprocess.run(["say", "-v", VOICE, "-o", aiff, text], check=True)
        raw = subprocess.run(["ffmpeg", "-v", "error", "-i", aiff, "-ac", "1", "-ar", str(RATE), "-f", "f32le", "-"],
                             capture_output=True, check=True).stdout
    x = np.frombuffer(raw, dtype=np.float32)
    # Trim to the sound: 5 ms frames above -45 dBFS.
    fr = RATE // 200
    e = np.array([np.sqrt(np.mean(x[i:i + fr] ** 2) + 1e-12) for i in range(0, len(x) - fr, fr)])
    on = np.flatnonzero(e > 10 ** (-45 / 20))
    return x[on[0] * fr:(on[-1] + 1) * fr] if len(on) else x

speech, words, t = [np.zeros(int(LEAD * RATE), np.float32)], [], LEAD
for s in SENTENCES:
    parts = s.split("*")
    for k, part in enumerate(parts):
        part = part.strip()
        if not part:
            continue
        seg = speak(part)
        if k % 2 == 1:  # a swear word
            words.append({"word": part, "start": round(t, 4), "end": round(t + len(seg) / RATE, 4)})
        speech += [seg, np.zeros(int(WORD_GAP * RATE), np.float32)]
        t += len(seg) / RATE + WORD_GAP
    speech.append(np.zeros(int(SENT_GAP * RATE), np.float32))
    t += SENT_GAP
voice = np.concatenate(speech + [np.zeros(int(2.0 * RATE), np.float32)])

raw = subprocess.run(["ffmpeg", "-v", "error", "-stream_loop", "-1", "-i", music_path, "-ac", "1", "-ar", str(RATE),
                      "-t", f"{len(voice) / RATE:.3f}", "-f", "f32le", "-"], capture_output=True, check=True).stdout
music = np.frombuffer(raw, dtype=np.float32)[:len(voice)]
rms = lambda a: np.sqrt(np.mean(a ** 2) + 1e-12)
music = music * (rms(voice[voice != 0]) / rms(music)) * 10 ** (-8 / 20)  # music 8 dB under the voice
mix = voice + music
mix = (mix / max(1.0, np.abs(mix).max() / 0.9)).astype(np.float32)
subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "f32le", "-ar", str(RATE), "-ac", "1", "-i", "-",
                os.path.join(out, "clip.wav")], input=mix.tobytes(), check=True)
json.dump(words, open(os.path.join(out, "words.json"), "w"), indent=1)
print(f"{len(mix) / RATE:.1f} s, {len(words)} swear words:", ", ".join(f"{w['word']} {w['start']:.2f}-{w['end']:.2f}" for w in words))
