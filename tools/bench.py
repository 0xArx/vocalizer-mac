# Parity (Core ML fp16 vs ONNX fp32) and speed per compute unit for each converted window size.
import sys, time, numpy as np, onnxruntime as ort, coremltools as ct
onnx_path, models = sys.argv[1], sys.argv[2]
sess = ort.InferenceSession(onnx_path, providers=["CPUExecutionProvider"])
rng = np.random.default_rng(0)
for dim_t in (256, 64, 32):
    x = (rng.standard_normal((1, 4, 3072, dim_t)) * np.linspace(3, 0.01, 3072)[None, None, :, None]).astype(np.float32)
    ref = sess.run(None, {"input": x})[0]
    for cu in ("CPU_AND_NE", "CPU_AND_GPU", "ALL"):
        m = ct.models.MLModel(f"{models}/MDXVocals{dim_t}.mlpackage", compute_units=getattr(ct.ComputeUnit, cu))
        y = m.predict({"input": x})["output"]
        snr = 10 * np.log10((ref ** 2).sum() / ((ref - y) ** 2).sum())
        for _ in range(2): m.predict({"input": x})
        t = time.perf_counter(); n = 5
        for _ in range(n): m.predict({"input": x})
        ms = (time.perf_counter() - t) / n * 1000
        audio_ms = dim_t * 1024 / 44.1
        print(f"dim_t {dim_t:3d} {cu:12s} {ms:7.1f} ms per call ({audio_ms:.0f} ms of audio) SNR vs onnx {snr:5.1f} dB")
