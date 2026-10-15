# Test fixture: macOS `say` speech over synthetic music (chords, bass, drums, lead synth).
# Writes fixtures/{mix,vocals}.f32 (interleaved stereo float32, 44.1 kHz).
import subprocess, os, sys, numpy as np
out = sys.argv[1] if len(sys.argv) > 1 else "fixtures"
os.makedirs(out, exist_ok=True)
sr = 44100
text = ("Peace be upon you. This is a longer test of the vocal separation model on the Mac. "
        "The quick brown fox jumps over the lazy dog, again and again, while the band keeps playing. "
        "Every word should come through clearly, and the drums, the bass and the melody should fade away. "
        "We measure how close the separated voice is to the original recording, in decibels. "
        "Higher is better. Then we do it again with a shorter window, to see what live mode costs.")
aiff = os.path.join(out, "speech.aiff")
subprocess.run(["say", "-o", aiff, text], check=True)
raw = subprocess.run(["ffmpeg", "-v", "error", "-i", aiff, "-ac", "1", "-ar", str(sr), "-f", "f32le", "-"],
                     check=True, capture_output=True).stdout
voice = np.frombuffer(raw, dtype=np.float32)
n = len(voice) + sr
t = np.arange(n) / sr
chords = [[220, 277.2, 329.6], [196, 246.9, 293.7], [174.6, 220, 261.6], [196, 246.9, 311.1]]
bar = (t // 1.5).astype(int) % 4
beat = t % 0.375
s = np.zeros(n)
for ci, ch in enumerate(chords):
    m = bar == ci
    for f in ch:
        for h in range(1, 7):
            s[m] += np.sin(2 * np.pi * f * h * t[m]) / h * np.exp(-(t[m] % 1.5) * 1.2)
bass = np.sin(2 * np.pi * np.array([c[0] for c in chords])[bar] / 2 * t) * 0.8
kick = np.sin(2 * np.pi * 55 * beat * (1 + 4 * np.exp(-beat * 30))) * np.exp(-beat * 18)
rng = np.random.default_rng(1)
hat = np.where((t % 0.1875) < 0.03, rng.uniform(-1, 1, n) * np.exp(-(t % 0.1875) * 120) * 0.4, 0)
notes = np.array([440, 494, 523, 587, 659, 587, 523, 494])
f_lead = notes[(t // 0.375).astype(int) % len(notes)]
phase = np.cumsum(2 * np.pi * f_lead / sr)
lead = sum(np.sin(h * phase) / h for h in range(1, 8)) * 0.15 * (0.6 + 0.4 * np.exp(-(t % 0.375) * 6))
music_l = 0.12 * s + 0.25 * bass + 0.6 * kick + hat + lead
music_r = 0.12 * s * 0.9 + 0.25 * bass + 0.6 * kick + 0.2 * hat + 0.8 * lead
v = np.zeros(n); off = sr // 2; v[off:off + len(voice)] = 0.6 * voice
mix = np.stack([v + 0.5 * music_l, v + 0.5 * music_r], 1).astype(np.float32)
voc = np.stack([v, v], 1).astype(np.float32)
mix.tofile(os.path.join(out, "mix.f32")); voc.tofile(os.path.join(out, "vocals.f32"))
print(f"{n / sr:.1f} s, mix SDR {10 * np.log10((voc ** 2).sum() / ((voc - mix) ** 2).sum()):.1f} dB")
