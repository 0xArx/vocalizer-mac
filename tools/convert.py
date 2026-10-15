# Converts the UVR MDX-Net vocals ONNX model to a Core ML ML Program.
# The network is convolutional in time (TDF MatMuls act on frequency), so dim_t is free
# as long as it is a multiple of 32; we export one model per window size.
#   .venv/bin/python convert.py <mdx-vocals.onnx> <out dir> [dim_t ...]
import sys, os, numpy as np, torch, onnx, coremltools as ct
from onnx2torch import convert

src, out = sys.argv[1], sys.argv[2]
dims = [int(x) for x in sys.argv[3:]] or [256, 64]
net = convert(onnx.load(src)).eval()
for dim_t in dims:
    x = torch.randn(1, 4, 3072, dim_t)
    traced = torch.jit.trace(net, x)
    ml = ct.convert(
        traced,
        inputs=[ct.TensorType(name="input", shape=x.shape)],
        outputs=[ct.TensorType(name="output")],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS14,
    )
    path = os.path.join(out, f"MDXVocals{dim_t}.mlpackage")
    ml.save(path)
    print("saved", path)
