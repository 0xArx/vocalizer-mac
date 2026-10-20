# Swear-word filter check: compares Vocalizer's output with the filter off and on, word by word.
#   .venv/bin/python analyze_profanity.py <source.wav (48 kHz mono)> <words.json> <off dir> <on dir>
import sys, json, subprocess, numpy as np
src_path, words_path, off_dir, on_dir = sys.argv[1:5]
def wav(p):
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", p, "-ac", "1", "-ar", "48000", "-f", "f32le", "-"], capture_output=True, check=True).stdout
    return np.frombuffer(raw, dtype=np.float32)
def rec(d, name): return np.fromfile(f"{d}/{name}.f32", dtype=np.float32).reshape(-1, 2).mean(1)
def lag(a, b, maxlag):  # shift s such that a[i] ~ b[i - s]
    n = 1 << int(np.ceil(np.log2(len(a) + len(b))))
    c = np.fft.irfft(np.fft.rfft(a, n) * np.conj(np.fft.rfft(b, n)), n)
    c = np.concatenate([c[-maxlag:], c[:maxlag]])
    return int(np.argmax(c)) - maxlag
src = wav(src_path); words = json.load(open(words_path))
def place(d):
    orig, out = rec(d, "original"), rec(d, "output")
    o = lag(orig, src, 48000 * 12)     # source sample i is at orig index i + o
    D = lag(out, orig, 48000 * 10)     # output is orig delayed by D
    return out, o + D
out_off, s_off = place(off_dir)
out_on, s_on = place(on_dir)
def rms(x): return float(np.sqrt(np.mean(x ** 2) + 1e-12)) if len(x) else 1e-6
full = part = 0
for w in words:
    a, b = int((w["start"] - 0.02) * 48000), int((w["end"] + 0.02) * 48000)
    e_off = rms(out_off[a + s_off:b + s_off]); e_on = rms(out_on[a + s_on:b + s_on])
    db = 20 * np.log10(e_off / max(e_on, 1e-9))
    verdict = "muted" if db > 20 else ("partly" if db > 6 else "MISSED")
    full += db > 20; part += 6 < db <= 20
    print(f"  {w['word']:9s} {w['start']:5.2f}-{w['end']:5.2f} s: {db:5.1f} dB quieter -> {verdict}")
# Clean speech elsewhere must be untouched: compare the whole output outside the swear words.
mask = np.ones(len(src), bool)
for w in words: mask[max(0, int((w["start"] - 0.6) * 48000)):int((w["end"] + 0.6) * 48000)] = False
idx = np.flatnonzero(mask[:min(len(src), len(out_off) - s_off, len(out_on) - s_on)])
other = 20 * np.log10(rms(out_off[idx + s_off]) / rms(out_on[idx + s_on]))
on_meta = json.load(open(f"{on_dir}/meta.json")); off_meta = json.load(open(f"{off_dir}/meta.json"))
print(f"  fully muted {full}/{len(words)}, partly {part} | other speech changed by {other:+.1f} dB | delay off {off_meta['pipelineLatencyMs']:.0f} ms, on {on_meta['pipelineLatencyMs']:.0f} ms | engine: muted {on_meta.get('wordsMuted')}, late {on_meta.get('wordsLate')}")
# Where did mutes actually land? 20 ms frames where the filtered output is >20 dB below the unfiltered one.
fr = 960
n = min(len(out_off) - s_off, len(out_on) - s_on, len(src)) // fr
spans, cur = [], None
for k in range(n):
    a = out_off[s_off + k * fr:s_off + (k + 1) * fr]; b = out_on[s_on + k * fr:s_on + (k + 1) * fr]
    muted = rms(a) > 0.003 and 20 * np.log10(rms(a) / max(rms(b), 1e-9)) > 20
    if muted and cur is None: cur = k
    if not muted and cur is not None: spans.append((cur * 0.02, k * 0.02)); cur = None
print("  muted spans (source time):", ", ".join(f"{a:.2f}-{b:.2f}" for a, b in spans if b - a >= 0.04))
print("  swear words (source time): ", ", ".join(f"{w['word']} {w['start']:.2f}-{w['end']:.2f}" for w in words))
# Precision (needs exact word times, e.g. tools/make_swear_fixture.py): per 10 ms, is the output muted?
fr = 480
n = min(len(out_off) - s_off, len(out_on) - s_on, len(src)) // fr
mutedf = np.zeros(n, bool)
for k in range(n):
    a = out_off[s_off + k * fr:s_off + (k + 1) * fr]; b = out_on[s_on + k * fr:s_on + (k + 1) * fr]
    mutedf[k] = rms(a) > 0.002 and 20 * np.log10(rms(a) / max(rms(b), 1e-9)) > 20
inword = np.zeros(n, bool); near = np.zeros(n, bool)
for w in words:
    inword[int(w["start"] * 100):int(w["end"] * 100) + 1] = True
    near[max(0, int((w["start"] - 0.03) * 100)):int((w["end"] + 0.03) * 100) + 1] = True  # 30 ms tolerance
print("  precision per word (share of the word muted | extra muted before / after it):")
for w in words:
    a, b = int(w["start"] * 100), int(w["end"] * 100) + 1
    cov = mutedf[a:b].mean() if b > a else 0
    k = a
    while k > 0 and mutedf[k - 1] and not inword[k - 1]: k -= 1
    before = (a - k) / 100
    k = b
    while k < n and mutedf[k] and not inword[k]: k += 1
    after = (k - b) / 100
    print(f"    {w['word']:9s} {cov * 100:5.0f}% muted | +{before:.2f} s before, +{after:.2f} s after")
skip = int(max(0, words[0]["start"] - 1.0) * 100)  # before the speech: start-up differences between runs
cut = (mutedf[skip:] & ~near[skip:]).sum() / 100
print(f"  OTHER SPEECH CUT: {cut:.2f} s in total (outside the swear words, beyond 30 ms)")
