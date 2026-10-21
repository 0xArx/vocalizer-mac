// "Supreme" mode: MelBand RoFormer vocals (Kimberley Jensen, MIT), the network converted to Core ML by
// tools/convert_roformer.py (GPU). STFT / mask / iSTFT run here, matching torch.stft / torch.istft
// (n_fft 2048, hop 441, periodic Hann, center=True with reflect padding).
//
// Streaming works like StreamingSeparator: every `step` samples the model sees the latest 8 s window and we
// keep the segment that ends `rightContext` before the window's valid edge. Delay = trim + right + step.

import Accelerate
import CoreML
import Foundation
import VocalizerObjC

public struct RoformerConfig {
    public var step: Int
    public var rightContext: Int
    public var fade: Int
    public init(step: Int, rightContext: Int, fade: Int) { self.step = step; self.rightContext = rightContext; self.fade = fade }
    /// 3 s steps with 1.5 s of future context: about 4.5 s of delay, hidden by video sync.
    public static let supreme = RoformerConfig(step: 132_300, rightContext: 66_150, fade: 4096)
}

/// Model description written next to the .mlpackage by convert_roformer.py.
struct RoformerInfo: Decodable {
    let frames: Int
    let n_fft: Int
    let hop: Int
    let chunk: Int
    let freq_indices: [Int]?
    let num_bands_per_freq: [Int]?
}

public final class RoformerSeparator: Separating {
    public let sampleRate = 44_100.0
    public let step: Int
    public let streamDelay: Int
    public var stem: OutputStem = .vocals
    public private(set) var lastStepTime = 0.0
    public private(set) var lastModelTime = 0.0

    private let config: RoformerConfig
    private let info: RoformerInfo
    private var model: MLModel
    private let compiledURL: URL
    private let modelConfig: MLModelConfiguration
    /// Model calls that failed and were replaced by silence.
    public private(set) var modelFailures = 0
    private let input: MLMultiArray
    private let inPtr: UnsafeMutablePointer<Float>
    private let provider: MLDictionaryFeatureProvider
    private let n: Int, hop: Int, frames: Int, chunk: Int, trim: Int, bins: Int
    private let window: [Float]
    private let invEnv: [Float]
    private let fft: vDSP_DFT_Setup, ifft: vDSP_DFT_Setup
    private var histL: [Float], histR: [Float]
    private var pendL: [Float] = [], pendR: [Float] = []
    private var specRe: [Float], specIm: [Float]   // [bins*2 (f s), frames] complex STFT of the window
    private var maskRe: [Float], maskIm: [Float]
    private var outL: [Float], outR: [Float]
    private var tailL: [Float], tailR: [Float]
    private let denom: [Float]

    /// `modelURL`: MelRoformerVocals.mlmodelc (or .mlpackage); `infoURL`: its .json.
    public init(modelURL: URL, infoURL: URL, config: RoformerConfig = .supreme) throws {
        self.config = config
        info = try JSONDecoder().decode(RoformerInfo.self, from: Data(contentsOf: infoURL))
        n = info.n_fft; hop = info.hop; frames = info.frames; chunk = info.chunk; trim = n / 2; bins = n / 2 + 1
        precondition(chunk - 2 * trim - config.rightContext - config.step >= 0, "segment does not fit the window")
        step = config.step
        streamDelay = trim + config.rightContext
        let compiled = modelURL.pathExtension == "mlmodelc" ? modelURL : try MDXModel.cachedCompile(modelURL)
        let mc = MLModelConfiguration()
        mc.computeUnits = .cpuAndGPU // measured: GPU 1.6 s per 8 s chunk; the Neural Engine is 3x slower here
        compiledURL = compiled
        modelConfig = mc
        model = try MLModel(contentsOf: compiled, configuration: mc)
        input = try MLMultiArray(shape: [1, NSNumber(value: bins * 2), NSNumber(value: frames), 2], dataType: .float32)
        inPtr = input.dataPointer.bindMemory(to: Float.self, capacity: input.count)
        provider = try MLDictionaryFeatureProvider(dictionary: ["spec": MLFeatureValue(multiArray: input)])

        let N = info.n_fft, H = info.hop, T = info.frames, C = info.chunk
        let win = (0..<N).map { 0.5 - 0.5 * cos(2 * Float.pi * Float($0) / Float(N)) }
        window = win
        var env = [Float](repeating: 0, count: C + N)
        for t in 0..<T { for i in 0..<N { env[t * H + i] += win[i] * win[i] } }
        invEnv = (0..<C).map { i in env[i + N / 2] > 1e-11 ? 1 / env[i + N / 2] : 0 }
        let fwd = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(N), .FORWARD)!
        fft = fwd
        ifft = vDSP_DFT_zop_CreateSetup(fwd, vDSP_Length(N), .INVERSE)!

        let B = N / 2 + 1
        histL = [Float](repeating: 0, count: C); histR = histL
        specRe = [Float](repeating: 0, count: B * 2 * T); specIm = specRe
        maskRe = specRe; maskIm = specRe
        outL = histL; outR = histL
        tailL = [Float](repeating: 0, count: config.fade); tailR = tailL
        // MelBand: bands overlap, so masks are averaged over the bands that cover each bin.
        if let per = info.num_bands_per_freq {
            denom = (0..<(B * 2)).map { max(1, Float(per[$0 / 2])) }
        } else {
            denom = [Float](repeating: 1, count: B * 2)
        }
        // The first GPU prediction is about 2x slower (shader compilation): do it now, not mid-song,
        // then time a warm one. The playback buffer must cover a whole model call.
        _ = try? model.prediction(from: provider)
        let w0 = CFAbsoluteTimeGetCurrent()
        _ = try? model.prediction(from: provider)
        TestSpeed.stretch(since: w0)
        modelCallTime = CFAbsoluteTimeGetCurrent() - w0
    }

    /// Seconds per warm model call on this Mac (about 1.6 s on an M-series GPU).
    public private(set) var modelCallTime = 0.0
    /// Safety buffer this Mac needs: 1.5x a model call plus 0.3 s, at least 0.7 s.
    public var recommendedJitterMs: Double { max(700, (modelCallTime * 1.5 + 0.3) * 1000) }

    /// Clears the audio history so the (expensive to load) model can be reused for a new run.
    public func reset() {
        for i in 0..<chunk { histL[i] = 0; histR[i] = 0 }
        pendL.removeAll(keepingCapacity: true); pendR.removeAll(keepingCapacity: true)
        for i in 0..<config.fade { tailL[i] = 0; tailR[i] = 0 }
    }

    deinit { vDSP_DFT_DestroySetup(ifft); vDSP_DFT_DestroySetup(fft) }

    public func push(left: UnsafePointer<Float>, right: UnsafePointer<Float>, count: Int) {
        pendL.append(contentsOf: UnsafeBufferPointer(start: left, count: count))
        pendR.append(contentsOf: UnsafeBufferPointer(start: right, count: count))
    }

    @discardableResult
    public func process(emit: (UnsafePointer<Float>, UnsafePointer<Float>, Int) -> Void) throws -> Bool {
        let step = config.step, fade = config.fade
        guard pendL.count >= step else { return false }
        let t0 = CFAbsoluteTimeGetCurrent()
        histL.removeFirst(step); histL.append(contentsOf: pendL[0..<step])
        histR.removeFirst(step); histR.append(contentsOf: pendR[0..<step])
        pendL.removeFirst(step); pendR.removeFirst(step)

        analyze()
        let t1 = CFAbsoluteTimeGetCurrent()
        do {
            try runModel()
        } catch {
            // Rare Core ML failure: silence for this step (keeps timing), reload the model for the next one.
            for i in 0..<maskRe.count { maskRe[i] = 0; maskIm[i] = 0 }
            modelFailures += 1
            if (error as NSError).domain == "VocalizerCoreMLException",
               let fresh = try? MLModel(contentsOf: compiledURL, configuration: modelConfig) { model = fresh }
        }
        lastModelTime = CFAbsoluteTimeGetCurrent() - t1
        synthesize()

        let start = chunk - trim - config.rightContext - step
        var segL = [Float](repeating: 0, count: step + fade), segR = segL
        let music = stem == .music
        for i in 0..<(step + fade) {
            var l = outL[start + i], r = outR[start + i]
            if music { l = histL[start + i] - l; r = histR[start + i] - r }
            segL[i] = l; segR[i] = r
        }
        for i in 0..<fade {
            let w = (Float(i) + 0.5) / Float(fade)
            segL[i] = segL[i] * w + tailL[i] * (1 - w)
            segR[i] = segR[i] * w + tailR[i] * (1 - w)
        }
        for i in 0..<fade { tailL[i] = segL[step + i]; tailR[i] = segR[step + i] }
        lastStepTime = CFAbsoluteTimeGetCurrent() - t0
        segL.withUnsafeBufferPointer { l in segR.withUnsafeBufferPointer { r in emit(l.baseAddress!, r.baseAddress!, step) } }
        return true
    }

    /// torch.stft(center=True, reflect) of both channels -> specRe/Im [(f s), t] and the model input [1, (f s), t, 2].
    private func analyze() {
        let half = trim
        var pL = [Float](repeating: 0, count: chunk + n), pR = pL
        for i in 0..<chunk { pL[half + i] = histL[i]; pR[half + i] = histR[i] }
        for i in 0..<half {
            pL[i] = histL[half - i]; pR[i] = histR[half - i]
            pL[half + chunk + i] = histL[chunk - 2 - i]; pR[half + chunk + i] = histR[chunk - 2 - i]
        }
        var re = [Float](repeating: 0, count: n), im = re, oRe = re, oIm = re
        let F2 = bins * 2
        for t in 0..<frames {
            let off = t * hop
            pL.withUnsafeBufferPointer { vDSP_vmul($0.baseAddress! + off, 1, window, 1, &re, 1, vDSP_Length(n)) }
            pR.withUnsafeBufferPointer { vDSP_vmul($0.baseAddress! + off, 1, window, 1, &im, 1, vDSP_Length(n)) }
            vDSP_DFT_Execute(fft, re, im, &oRe, &oIm)
            for f in 0..<bins {
                // Unpack z = L + iR: L[k] = (Z[k] + conj(Z[N-k])) / 2, R[k] = (Z[k] - conj(Z[N-k])) / (2i)
                let g = f == 0 ? 0 : n - f
                let zr = oRe[f], zi = oIm[f], wr = oRe[g], wi = oIm[g]
                let lr = (zr + wr) / 2, li = (zi - wi) / 2
                let rr = (zi + wi) / 2, ri = -(zr - wr) / 2
                let a = (2 * f) * frames + t, b = (2 * f + 1) * frames + t
                specRe[a] = lr; specIm[a] = li
                specRe[b] = rr; specIm[b] = ri
                let ia = ((2 * f) * frames + t) * 2, ib = ((2 * f + 1) * frames + t) * 2
                inPtr[ia] = lr; inPtr[ia + 1] = li
                inPtr[ib] = rr; inPtr[ib + 1] = ri
            }
        }
        _ = F2
    }

    /// Runs the network and turns its (band) mask into a full complex mask per (f s) bin.
    private func runModel() throws {
        var nsError: NSError?
        let t0 = CFAbsoluteTimeGetCurrent()
        defer { TestSpeed.stretch(since: t0) }
        guard let out = VCLPredict(model, provider, MLPredictionOptions(), &nsError) else {
            throw nsError ?? NSError(domain: "Roformer", code: 2, userInfo: [NSLocalizedDescriptionKey: "prediction failed"])
        }
        guard let arr = out.featureValue(for: "mask")?.multiArrayValue else {
            throw NSError(domain: "Roformer", code: 1, userInfo: [NSLocalizedDescriptionKey: "model returned no mask"])
        }
        let s = arr.strides.map(\.intValue)
        let rows = arr.shape[1].intValue
        for i in 0..<maskRe.count { maskRe[i] = 0; maskIm[i] = 0 }
        func read(_ body: (Int, Int, Float, Float) -> Void, _ get: (Int) -> Float) {
            for j in 0..<rows { for t in 0..<frames {
                let o = j * s[1] + t * s[2]
                body(j, t, get(o), get(o + s[3]))
            } }
        }
        let indices = info.freq_indices
        let accumulate: (Int, Int, Float, Float) -> Void = { j, t, r, i in
            let row = indices?[j] ?? j
            self.maskRe[row * self.frames + t] += r
            self.maskIm[row * self.frames + t] += i
        }
        if arr.dataType == .float32 {
            arr.withUnsafeBufferPointer(ofType: Float.self) { p in read(accumulate) { p[$0] } }
        } else {
            let p = arr.dataPointer.bindMemory(to: Float16.self, capacity: arr.count)
            read(accumulate) { Float(p[$0]) }
        }
        for row in 0..<(bins * 2) {
            let d = 1 / denom[row]
            for t in 0..<frames { maskRe[row * frames + t] *= d; maskIm[row * frames + t] *= d }
        }
    }

    /// Y = X * M, then torch.istft(center=True) per channel into outL / outR (chunk samples).
    private func synthesize() {
        var accL = [Float](repeating: 0, count: chunk + n), accR = accL
        var re = [Float](repeating: 0, count: n), im = re, oRe = re, oIm = re
        let scale = 1 / Float(n)
        for t in 0..<frames {
            for k in 0..<n { re[k] = 0; im[k] = 0 }
            // Pack both channels: Z[k] = L[k] + i R[k] (k <= N/2), conj-mirrored above, so ifft = l + i r.
            for f in 0..<bins {
                let a = (2 * f) * frames + t, b = (2 * f + 1) * frames + t
                let lr = specRe[a] * maskRe[a] - specIm[a] * maskIm[a]
                let li = f == 0 || f == bins - 1 ? 0 : specRe[a] * maskIm[a] + specIm[a] * maskRe[a]
                let rr = specRe[b] * maskRe[b] - specIm[b] * maskIm[b]
                let ri = f == 0 || f == bins - 1 ? 0 : specRe[b] * maskIm[b] + specIm[b] * maskRe[b]
                re[f] = lr - ri; im[f] = li + rr
                if f > 0 && f < n / 2 { re[n - f] = lr + ri; im[n - f] = -li + rr }
            }
            vDSP_DFT_Execute(ifft, re, im, &oRe, &oIm)
            let off = t * hop
            for i in 0..<n {
                accL[off + i] += oRe[i] * scale * window[i]
                accR[off + i] += oIm[i] * scale * window[i]
            }
        }
        for i in 0..<chunk {
            outL[i] = accL[trim + i] * invEnv[i]
            outR[i] = accR[trim + i] * invEnv[i]
        }
    }
}
