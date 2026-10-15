# Measures the real end-to-end delay and quality from a loopback recording (LoopbackTest).
#   .venv/bin/python analyze_loopback.py <loop dir> <fixture dir with mix.f32 + vocals.f32>
import sys, os, json, subprocess, numpy as np
loop, fx = sys.argv[1], sys.argv[2]
meta = json.load(open(os.path.join(loop, "meta.json")))
rate = int(meta["rate"])

def load44(path):
    if rate == 44100:
        return np.fromfile(path, dtype=np.float32).reshape(-1, 2)
    raw = subprocess.run(["ffmpeg", "-v", "error", "-f", "f32le", "-ar", str(rate), "-ac", "2", "-i", path, "-af", "aresample=filter_size=64",
                          "-ar", "44100", "-f", "f32le", "-"],
                         check=True, capture_output=True).stdout
    return np.frombuffer(raw, dtype=np.float32).reshape(-1, 2)

orig, out = load44(os.path.join(loop, "original.f32")), load44(os.path.join(loop, "output.f32"))
mix = np.fromfile(os.path.join(fx, "mix.f32"), dtype=np.float32).reshape(-1, 2)
voc = np.fromfile(os.path.join(fx, "vocals.f32"), dtype=np.float32).reshape(-1, 2)

def offset(rec, ref, seg=44100 * 4, start=44100 * 2):
    """Index in ref where rec[start] lines up (FFT cross-correlation of a 4 s piece)."""
    a = rec[start:start + seg].mean(1)
    b = ref.mean(1)
    n = 1 << int(np.ceil(np.log2(len(a) + len(b))))
    c = np.fft.irfft(np.fft.rfft(b, n) * np.conj(np.fft.rfft(a, n)), n)[: len(b)]
    return int(np.argmax(c)) - start

offA = offset(orig, mix)
offB = offset(out, voc, start=44100 * 3)
delay = offA - offB
print(f"rate {rate} Hz, mode {meta['mode']}, recorded {len(orig) / 44100:.1f} s")
print(f"measured delay (tap in -> our output): {delay} samples = {delay / 44.1:.1f} ms "
      f"(engine reports {meta['pipelineLatencyMs']:.1f} ms pipeline, device adds {meta['deviceLatencyMs']:.1f} ms)")

def sdr(ref, est):
    return 10 * np.log10((ref ** 2).sum() / ((ref - est) ** 2).sum())

def si_sdr(ref, est):
    r, e = ref.ravel(), est.ravel()
    a = (e @ r) / (r @ r)
    return 10 * np.log10(((a * r) ** 2).sum() / ((a * r - e) ** 2).sum())

print(f"alignment: recording starts at source sample {offA}, output at {offB}")
lo = max(44100 * 2, -offB + 44100)  # skip warm-up and the initial silence
hi = min(len(out), len(voc) - offB) - 44100
est = out[lo:hi]
ref = voc[lo + offB:hi + offB]
refmix = mix[lo + offA:hi + offA]
print(f"original tap vs source mix: SDR {sdr(refmix, orig[lo:hi]):.1f} dB (capture fidelity)")
print(f"our output vs true vocals : SDR {sdr(ref, est):.2f} dB, SI-SDR {si_sdr(ref, est):.2f} dB "
      f"over {len(est) / 44100:.1f} s (doing nothing would score {sdr(ref, mix[lo + offB:hi + offB]):.1f} dB)")
print(f"compute: RTF {meta['realTimeFactor']:.3f}, step {meta['stepMs']:.1f} ms (model {meta['modelMs']:.1f}), "
      f"worst {meta['worstStepMs']:.1f} ms, underruns {meta['underruns']}")
