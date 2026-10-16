// Offline benchmark for the streaming separator: SDR against the true vocals, latency and speed.
//   vocalizer-bench <models dir> <fixtures dir> [cpu|gpu|ane|all] [presets|sweep] [max seconds]

import CoreML
import Foundation
import VocalizerCore

let args = CommandLine.arguments
let modelsDir = URL(fileURLWithPath: args.count > 1 ? args[1] : "Models")
let fixtures = URL(fileURLWithPath: args.count > 2 ? args[2] : "fixtures")
let units: MLComputeUnits = switch args.count > 3 ? args[3] : "all" {
case "cpu": .cpuOnly
case "gpu": .cpuAndGPU
case "ane": .cpuAndNeuralEngine
default: .all
}

func load(_ name: String) -> [Float] {
    let d = try! Data(contentsOf: fixtures.appendingPathComponent(name))
    return d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
}
let maxSeconds = args.count > 5 ? Double(args[5])! : .infinity
let mix = load("mix.f32"), ref = load("vocals.f32")
let n = min(mix.count / 2, maxSeconds.isFinite ? Int(maxSeconds * 44_100) : Int.max)
let mixL = (0..<n).map { mix[2 * $0] }, mixR = (0..<n).map { mix[2 * $0 + 1] }
let refL = (0..<n).map { ref[2 * $0] }, refR = (0..<n).map { ref[2 * $0 + 1] }
// Optional segments.txt (sample count per track): also report the median per-track SDR.
let segments: [Int] = (try? String(contentsOf: fixtures.appendingPathComponent("segments.txt"), encoding: .utf8))
    .map { $0.split(separator: "\n").compactMap { Int($0) } } ?? []

func sdr(_ estL: [Float], _ estR: [Float], from: Int, to: Int) -> Double {
    var num = 0.0, den = 0.0
    for i in from..<to {
        num += Double(refL[i] * refL[i] + refR[i] * refR[i])
        let a = Double(refL[i] - estL[i]), b = Double(refR[i] - estR[i])
        den += a * a + b * b
    }
    return 10 * log10(num / den)
}

func modelURL(_ frames: Int) -> URL {
    let c = modelsDir.appendingPathComponent("MDXVocals\(frames).mlmodelc")
    return FileManager.default.fileExists(atPath: c.path) ? c : modelsDir.appendingPathComponent("MDXVocals\(frames).mlpackage")
}

var models: [Int: MDXModel] = [:]
func model(_ frames: Int) -> MDXModel {
    if let m = models[frames] { return m }
    let t = CFAbsoluteTimeGetCurrent()
    let m = try! MDXModel(url: modelURL(frames), frames: frames, computeUnits: units)
    print(String(format: "  loaded %d-frame model in %.2f s", frames, CFAbsoluteTimeGetCurrent() - t))
    models[frames] = m
    return m
}

func cfg(_ frames: Int, stepMs: Double, rightMs: Double, fade: Int) -> SeparatorConfig {
    let step = Int((stepMs * 44.1).rounded()), right = max(fade, Int((rightMs * 44.1).rounded()))
    return SeparatorConfig(frames: frames, step: step, rightContext: right, fade: fade)
}

let chunk256 = MDX.chunk(frames: 256)
let presetsOnly = args.count > 4 && args[4] == "presets"
let allConfigs: [(String, SeparatorConfig)] = [
    ("offline-like (centred)", SeparatorConfig(frames: 256, step: 44_100, rightContext: (chunk256 - 2 * MDX.trim - 44_100) / 2, fade: 2048)),
    ("QUALITY preset", .quality),
    ("BALANCED preset", .balanced),
    ("256, 1 s step, 0.5 s ctx", cfg(256, stepMs: 1000, rightMs: 500, fade: 2048)),
    ("256, 0.25 s step, 0.1 s ctx", cfg(256, stepMs: 250, rightMs: 100, fade: 1024)),
    ("64, 0.19 s step, 0.2 s ctx", cfg(64, stepMs: 186, rightMs: 200, fade: 1024)),
    ("64, 0.09 s step, 0.07 s ctx", cfg(64, stepMs: 93, rightMs: 70, fade: 1024)),
    ("LIVE preset", .live),
    ("32, 0.05 s step, 0 ctx", SeparatorConfig(frames: 32, step: 2048, rightContext: 512, fade: 512)),
]
let configs = presetsOnly ? allConfigs.filter { $0.0.contains("preset") || $0.0.hasPrefix("offline") } : allConfigs

print("fixture: \(String(format: "%.1f", Double(n) / 44_100)) s, compute units: \(args.count > 3 ? args[3] : "all")")
print("mix SDR (doing nothing): " + String(format: "%.1f dB", sdr(mixL, mixR, from: 44_100, to: n - 44_100)))
print("config                          | latency | SDR     | step ms (model) | real-time factor")
for (name, c) in configs {
    let sep = StreamingSeparator(config: c, model: model(c.frames))
    var outL: [Float] = [], outR: [Float] = []
    var compute = 0.0, modelTime = 0.0, steps = 0, worst = 0.0
    // Feed in 512-sample blocks like an audio callback, then flush with silence.
    let block = 512
    var pos = 0
    let zeros = [Float](repeating: 0, count: block)
    while outL.count < n + c.streamDelay {
        mixL.withUnsafeBufferPointer { l in mixR.withUnsafeBufferPointer { r in
            if pos + block <= n {
                sep.push(left: l.baseAddress! + pos, right: r.baseAddress! + pos, count: block)
            } else {
                zeros.withUnsafeBufferPointer { z in sep.push(left: z.baseAddress!, right: z.baseAddress!, count: block) }
            }
        } }
        pos += block
        while try! sep.process(emit: { l, r, k in
            outL.append(contentsOf: UnsafeBufferPointer(start: l, count: k))
            outR.append(contentsOf: UnsafeBufferPointer(start: r, count: k))
        }) {
            compute += sep.lastStepTime; modelTime += sep.lastModelTime; steps += 1
            worst = max(worst, sep.lastStepTime)
        }
    }
    let d = c.streamDelay
    let estL = Array(outL[d..<(d + n)]), estR = Array(outR[d..<(d + n)])
    let score = sdr(estL, estR, from: 44_100, to: n - 44_100)
    var median = ""
    if segments.first.map({ $0 <= n }) == true {
        var start = 0, scores: [Double] = []
        for len in segments where start + len <= n { scores.append(sdr(estL, estR, from: start, to: start + len)); start += len }
        median = String(format: " | median %.2f dB", scores.sorted()[scores.count / 2])
    }
    let rtf = compute / (Double(pos) / 44_100)
    print(String(format: "%-31@ | %4.0f ms | %5.2f dB | %5.1f (%5.1f) max %5.1f | %.3f (%.0fx real time)%@",
                 name as NSString, c.latencyMs, score, compute / Double(steps) * 1000, modelTime / Double(steps) * 1000,
                 worst * 1000, rtf, 1 / rtf, median as NSString))
}

// Ultra fast mode (DeepFilterNet3), if DF_LIB and DF_MODEL point at libdf.dylib and the model tarball.
if let lib = ProcessInfo.processInfo.environment["DF_LIB"], let mdl = ProcessInfo.processInfo.environment["DF_MODEL"] {
    let df = try! DeepFilterSeparator(library: URL(fileURLWithPath: lib), model: URL(fileURLWithPath: mdl))
    let up = StreamResampler(from: 44_100, to: 48_000), down = StreamResampler(from: 48_000, to: 44_100)
    var outL: [Float] = [], outR: [Float] = []
    var compute = 0.0, worst = 0.0
    let block = 4410
    var pos = 0
    while pos < n {
        let k = min(block, n - pos)
        mixL.withUnsafeBufferPointer { l in mixR.withUnsafeBufferPointer { r in up.process(left: l.baseAddress! + pos, right: r.baseAddress! + pos, count: k) } }
        df.push(left: up.outL, right: up.outR, count: up.outL.count)
        while try! df.process(emit: { l, r, m in
            down.process(left: l, right: r, count: m)
            outL += down.outL; outR += down.outR
        }) { compute += df.lastStepTime; worst = max(worst, df.lastStepTime) }
        pos += k
    }
    // Find the delay by searching for the best-matching lag against the true vocals.
    var best = (lag: 0, score: -Double.infinity)
    for lag in stride(from: 0, to: 4000, by: 1) {
        var dot = 0.0
        for i in stride(from: 44_100, to: min(44_100 * 11, outL.count - lag), by: 3) { dot += Double(outL[i + lag] * refL[i]) }
        if dot > best.score { best = (lag, dot) }
    }
    let m = min(outL.count - best.lag, n)
    let estL = Array(outL[best.lag..<(best.lag + m)]) + [Float](repeating: 0, count: n - m)
    let estR = Array(outR[best.lag..<(best.lag + m)]) + [Float](repeating: 0, count: n - m)
    var median = ""
    if segments.first.map({ $0 <= n }) == true {
        var start = 0, scores: [Double] = []
        for len in segments where start + len <= n { scores.append(sdr(estL, estR, from: start, to: start + len)); start += len }
        median = String(format: " | median %.2f dB", scores.sorted()[scores.count / 2])
    }
    let rtf = compute / (Double(n) / 44_100)
    print(String(format: "%-31@ | %4.0f ms | %5.2f dB | %5.2f ms per 10 ms frame, max %5.1f | %.3f (%.0fx real time)%@",
                 "ULTRA FAST (DeepFilterNet3)" as NSString, Double(best.lag) / 44.1, sdr(estL, estR, from: 44_100, to: n - 44_100),
                 compute / Double(n / 441) * 1000, worst * 1000, rtf, 1 / rtf, median as NSString))
}

// Supreme mode (MelBand RoFormer), if ROFORMER points at MelRoformerVocals.mlmodelc (with its .json next to it).
if let path = ProcessInfo.processInfo.environment["ROFORMER"] {
    let url = URL(fileURLWithPath: path)
    let info = url.deletingPathExtension().appendingPathExtension("json")
    let t0 = CFAbsoluteTimeGetCurrent()
    let sep = try! RoformerSeparator(modelURL: url, infoURL: info)
    print(String(format: "  loaded RoFormer in %.1f s", CFAbsoluteTimeGetCurrent() - t0))
    var outL: [Float] = [], outR: [Float] = []
    var compute = 0.0, modelT = 0.0, steps = 0, worst = 0.0
    let block = 4410
    var pos = 0
    let zeros = [Float](repeating: 0, count: block)
    while outL.count < n + sep.streamDelay {
        mixL.withUnsafeBufferPointer { l in mixR.withUnsafeBufferPointer { r in
            if pos + block <= n { sep.push(left: l.baseAddress! + pos, right: r.baseAddress! + pos, count: block) }
            else { zeros.withUnsafeBufferPointer { z in sep.push(left: z.baseAddress!, right: z.baseAddress!, count: block) } }
        } }
        pos += block
        while try! sep.process(emit: { l, r, k in
            outL.append(contentsOf: UnsafeBufferPointer(start: l, count: k))
            outR.append(contentsOf: UnsafeBufferPointer(start: r, count: k))
        }) { compute += sep.lastStepTime; modelT += sep.lastModelTime; steps += 1; worst = max(worst, sep.lastStepTime) }
    }
    let d = sep.streamDelay
    let estL = Array(outL[d..<(d + n)]), estR = Array(outR[d..<(d + n)])
    var median = ""
    if segments.first.map({ $0 <= n }) == true {
        var start = 0, scores: [Double] = []
        for len in segments where start + len <= n { scores.append(sdr(estL, estR, from: start, to: start + len)); start += len }
        median = String(format: " | median %.2f dB", scores.sorted()[scores.count / 2])
    }
    let rtf = compute / (Double(pos) / 44_100)
    print(String(format: "%-31@ | %4.0f ms | %5.2f dB | %6.1f (%6.1f) max %6.1f | %.3f (%.1fx real time)%@",
                 "SUPREME (MelBand RoFormer)" as NSString, Double(sep.streamDelay + sep.step) / 44.1,
                 sdr(estL, estR, from: 44_100, to: n - 44_100), compute / Double(steps) * 1000, modelT / Double(steps) * 1000,
                 worst * 1000, rtf, 1 / rtf, median as NSString))
}
