# Converts a BS-/MelBand-RoFormer vocal model (audio-separator / ZFTurbo checkpoint + yaml) to Core ML.
# Only the network: input = stereo STFT [1, 2*1025 (freq-major, stereo interleaved), T, 2 (re,im)],
# output = complex mask, same shape. STFT / iSTFT / mask multiply run in Swift.
#   .venv/bin/python convert_roformer.py <ckpt> <yaml> <out.mlpackage> [frames=801]
import sys, time, yaml, torch, numpy as np, coremltools as ct
from audio_separator.separator.uvr_lib_v5.roformer.bs_roformer import BSRoformer
from audio_separator.separator.uvr_lib_v5.roformer.mel_band_roformer import MelBandRoformer
from einops import rearrange, pack, unpack
import coremltools.converters.mil.frontend.torch.ops as _ops
from coremltools.converters.mil import Builder as _mb

# einops shape arithmetic traces to int() of a 1-element tensor; coremltools only accepts 0-d there.
_orig_cast = _ops._cast
def _cast(context, node, dtype, dtype_name):
    x = context[node.inputs[0]]
    if x.val is not None and getattr(x.val, "size", 0) == 1 and getattr(x.val, "ndim", 0) > 0:
        context.add(_mb.const(val=dtype(x.val.reshape(()).item()), name=node.name)); return
    return _orig_cast(context, node, dtype, dtype_name)
_ops._cast = _cast

ckpt, cfg_path, out = sys.argv[1], sys.argv[2], sys.argv[3]
frames = int(sys.argv[4]) if len(sys.argv) > 4 else 801
cfg = yaml.load(open(cfg_path), Loader=yaml.FullLoader)
m = dict(cfg["model"]); m.pop("flash_attn", None)
for k in list(m):
    if isinstance(m[k], list): m[k] = tuple(m[k])
cls = MelBandRoformer if "num_bands" in m else BSRoformer
net = cls(**m)
sd = torch.load(ckpt, map_location="cpu", weights_only=False)
net.load_state_dict(sd.get("state_dict", sd), strict=False)
net.eval()

class Core(torch.nn.Module):
    """band split -> axial transformers -> mask estimator (no STFT)."""
    def __init__(self, n): super().__init__(); self.n = n
    def forward(self, spec):  # [1, F2, T, 2]
        n = self.n
        if hasattr(n, "freq_indices"):  # MelBand: overlapping mel bands; Swift averages them back
            spec = torch.index_select(spec, 1, n.freq_indices)
        x = rearrange(spec, "b f t c -> b t (f c)")
        x = n.band_split(x)
        for block in n.layers:
            if len(block) == 3:
                lin, tt, ft = block
                x, ps0 = pack([x], "b * d"); x = lin(x); (x,) = unpack(x, ps0, "b * d")
            else:
                tt, ft = block
            x = rearrange(x, "b t f d -> b f t d"); x, ps = pack([x], "* t d"); x = tt(x); (x,) = unpack(x, ps, "* t d")
            x = rearrange(x, "b f t d -> b t f d"); x, ps = pack([x], "* f d"); x = ft(x); (x,) = unpack(x, ps, "* f d")
        if hasattr(n, "final_norm"): x = n.final_norm(x)
        mask = n.mask_estimators[0](x)
        return rearrange(mask, "b t (f c) -> b f t c", c=2)

core = Core(net).eval()
import json, os
side = {"kind": cls.__name__, "frames": frames, "n_fft": m.get("stft_n_fft", 2048), "hop": m.get("stft_hop_length", 441),
        "chunk": cfg["audio"]["chunk_size"], "sample_rate": cfg["audio"]["sample_rate"]}
if hasattr(net, "freq_indices"):
    side["freq_indices"] = net.freq_indices.tolist()
    side["num_bands_per_freq"] = net.num_bands_per_freq.tolist()
json.dump(side, open(os.path.splitext(out)[0] + ".json", "w"))
print("frames", frames, "kind", cls.__name__, "outputs", "band mask" if hasattr(net, "freq_indices") else "full mask")
F2 = 1025 * 2
x = torch.randn(1, F2, frames, 2) * 0.1
with torch.no_grad():
    ref = core(x)
    for dev in ["cpu", "mps"]:
        try:
            c = core.to(dev); xi = x.to(dev); c(xi)
            t = time.time(); c(xi); (torch.mps.synchronize() if dev == "mps" else None); print(f"torch {dev}: {time.time()-t:.2f} s per {frames}-frame chunk")
        except Exception as e: print(dev, "failed", e)
    core = core.to("cpu")
    traced = torch.jit.trace(core, x)
ml = ct.convert(traced, inputs=[ct.TensorType(name="spec", shape=x.shape)], outputs=[ct.TensorType(name="mask")],
                convert_to="mlprogram", compute_precision=ct.precision.FLOAT16, minimum_deployment_target=ct.target.macOS14)
ml.save(out)
for cu in ["CPU_AND_GPU", "ALL", "CPU_AND_NE"]:
    mm = ct.models.MLModel(out, compute_units=getattr(ct.ComputeUnit, cu))
    y = mm.predict({"spec": x.numpy()})["mask"]; mm.predict({"spec": x.numpy()})
    t = time.time(); mm.predict({"spec": x.numpy()}); dt = time.time() - t
    snr = 10 * np.log10((ref.numpy() ** 2).sum() / ((ref.numpy() - y) ** 2).sum())
    print(f"coreml {cu}: {dt:.2f} s per chunk, SNR vs torch {snr:.1f} dB")
