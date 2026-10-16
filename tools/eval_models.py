# Offline quality check of separation models on the MUSDB fixture (same 60 s for all), via audio-separator.
#   .venv/bin/python eval_models.py <fixture dir> <out dir> model1.ckpt model2.ckpt ...
import sys, os, time, numpy as np, soundfile as sf
from audio_separator.separator import Separator
fx, out = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)
mix = np.fromfile(os.path.join(fx, "mix.f32"), dtype=np.float32).reshape(-1, 2)[: 44100 * 60]
voc = np.fromfile(os.path.join(fx, "vocals.f32"), dtype=np.float32).reshape(-1, 2)[: 44100 * 60]
wav = os.path.join(out, "mix60.wav"); sf.write(wav, mix, 44100, subtype="FLOAT")
lens = [int(x) for x in open(os.path.join(fx, "segments.txt")).read().split()]
def sdr(ref, est): return 10 * np.log10((ref ** 2).sum() / ((ref - est) ** 2).sum() + 1e-12)
for name in sys.argv[3:]:
    sep = Separator(output_dir=out, model_file_dir=os.path.join(out, "models"), output_format="WAV", output_single_stem="Vocals")
    sep.load_model(model_filename=name)
    t = time.time(); files = sep.separate(wav); dt = time.time() - t
    est, sr = sf.read(os.path.join(out, files[0]) if not os.path.isabs(files[0]) else files[0], dtype="float32")
    n = min(len(est), len(voc)); est = est[:n]; ref = voc[:n]
    per, start = [], 0
    for L in lens:
        if start + L > n: break
        per.append(sdr(ref[start:start + L], est[start:start + L])); start += L
    print(f"{name:55s} SDR {sdr(ref[44100:n-44100], est[44100:n-44100]):6.2f} dB | median {np.median(per):6.2f} | {dt:5.1f} s for 60 s audio (RTF {dt/60:.2f})", flush=True)
