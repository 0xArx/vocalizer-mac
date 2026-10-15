# Real-music fixture: MUSDB18 7 s sample excerpts (test set) with a clear vocal, concatenated.
# Writes <out>/musdb/{mix,vocals}.f32 (interleaved stereo float32, 44.1 kHz) and segments.txt.
import sys, os, numpy as np, musdb
out = sys.argv[1] if len(sys.argv) > 1 else "fixtures"
db = musdb.DB(root=os.path.join(out, "musdb"), download=True, subsets="test")
mixes, vocs = [], []
for tr in db:
    v = tr.targets["vocals"].audio.astype(np.float32)
    m = tr.audio.astype(np.float32)
    if (v ** 2).mean() < 0.1 * (m ** 2).mean():  # skip excerpts with little singing
        continue
    mixes.append(m); vocs.append(v)
    if len(mixes) == 16: break
lens = [len(m) for m in mixes]
d = os.path.join(out, "musdb-fixture"); os.makedirs(d, exist_ok=True)
np.concatenate(mixes).tofile(os.path.join(d, "mix.f32"))
np.concatenate(vocs).tofile(os.path.join(d, "vocals.f32"))
open(os.path.join(d, "segments.txt"), "w").write("\n".join(map(str, lens)))
print(len(mixes), "tracks,", sum(lens) / 44100, "s")
