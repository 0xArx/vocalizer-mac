// Sliding-window MDX separation for live audio (44.1 kHz stereo).
//
// Every `step` new input samples, the model runs on the latest window of `frames` STFT frames.
// From that window we keep the segment that ends `rightContext` samples before the valid end,
// so each output sample has seen `rightContext + trim` samples of the future. Neighbouring
// segments crossfade over `fade` samples.
//
//   window:  |trim| ............ valid ............ |trim|
//                         [ segment (step) ][fade]
//                                                 ^ rightContext ^
//
// The output stream is the input delayed by `trim + rightContext` samples, produced in bursts
// of `step`, so the minimum playback delay is `trim + rightContext + step` plus compute time.

import Foundation

public struct SeparatorConfig: Equatable, CustomStringConvertible {
    public var frames: Int
    public var step: Int
    public var rightContext: Int
    public var fade: Int

    public init(frames: Int, step: Int, rightContext: Int, fade: Int) {
        self.frames = frames; self.step = step; self.rightContext = rightContext; self.fade = fade
        precondition(rightContext >= fade, "rightContext must cover the crossfade")
        precondition(MDX.chunk(frames: frames) - 2 * MDX.trim - rightContext - step >= 0, "segment does not fit the window")
    }

    /// Delay between an input sample and the same sample in the output stream.
    public var streamDelay: Int { MDX.trim + rightContext }
    /// Minimum playback delay (before compute time and audio buffers).
    public var algorithmicLatency: Int { streamDelay + step }
    public var latencyMs: Double { Double(algorithmicLatency) / MDX.sampleRate * 1000 }

    public var description: String {
        String(format: "frames %d, step %.0f ms, right context %.0f ms, fade %d -> %.0f ms",
               frames, Double(step) / 44.1, Double(rightContext) / 44.1, fade, latencyMs)
    }

    /// Lowest latency: 0.74 s window, 46 ms steps, about 157 ms algorithmic delay.
    public static let live = SeparatorConfig(frames: 32, step: 2048, rightContext: 1024, fade: 1024)
    /// 1.5 s window, 93 ms steps, about 250 ms delay. Slightly better than live.
    public static let balanced = SeparatorConfig(frames: 64, step: 4096, rightContext: 3072, fade: 1024)
    /// Full 5.9 s window with 0.5 s of future context, 1 s steps, about 1.6 s delay (matches offline quality).
    public static let quality = SeparatorConfig(frames: 256, step: 44_100, rightContext: 22_050, fade: 2048)
}

public enum OutputStem: Int { case vocals = 0, music = 1 }

/// What the engine needs from a separator (MDX-Net or DeepFilterNet).
public protocol Separating: AnyObject {
    var sampleRate: Double { get }
    /// Samples per processing step (output arrives in bursts of this size).
    var step: Int { get }
    /// Output sample k is input sample k - streamDelay.
    var streamDelay: Int { get }
    var stem: OutputStem { get set }
    var lastStepTime: Double { get }
    var lastModelTime: Double { get }
    func push(left: UnsafePointer<Float>, right: UnsafePointer<Float>, count: Int)
    @discardableResult func process(emit: (UnsafePointer<Float>, UnsafePointer<Float>, Int) -> Void) throws -> Bool
}

public final class StreamingSeparator: Separating {
    public var sampleRate: Double { MDX.sampleRate }
    public var step: Int { config.step }
    public var streamDelay: Int { config.streamDelay }
    public let config: SeparatorConfig
    public var stem: OutputStem = .vocals
    private let spec: MDXSpectrogram
    private let model: MDXModel
    private let chunk: Int
    private var histL: [Float], histR: [Float] // last `chunk` input samples
    private var pendL: [Float] = [], pendR: [Float] = []
    private var outL: [Float], outR: [Float] // istft scratch
    private var tailL: [Float], tailR: [Float] // previous segment's crossfade tail
    /// Seconds spent per step (STFT + model + iSTFT), and model only.
    public private(set) var lastStepTime = 0.0
    public private(set) var lastModelTime = 0.0
    /// Model calls that failed and were replaced by silence.
    public private(set) var modelFailures = 0

    public init(config: SeparatorConfig, model: MDXModel) {
        precondition(model.frames == config.frames)
        self.config = config
        self.model = model
        spec = MDXSpectrogram(frames: config.frames)
        chunk = spec.chunk
        histL = [Float](repeating: 0, count: chunk); histR = histL
        outL = histL; outR = histL
        tailL = [Float](repeating: 0, count: config.fade); tailR = tailL
    }

    public func reset() {
        for i in 0..<chunk { histL[i] = 0; histR[i] = 0 }
        pendL.removeAll(keepingCapacity: true); pendR.removeAll(keepingCapacity: true)
        for i in 0..<config.fade { tailL[i] = 0; tailR[i] = 0 }
    }

    /// Queue planar input; call `process` to run whatever full steps are available.
    public func push(left: UnsafePointer<Float>, right: UnsafePointer<Float>, count: Int) {
        pendL.append(contentsOf: UnsafeBufferPointer(start: left, count: count))
        pendR.append(contentsOf: UnsafeBufferPointer(start: right, count: count))
    }

    public var pending: Int { pendL.count }

    /// Runs one step if `step` samples are queued; emits `step` output samples (planar).
    @discardableResult
    public func process(emit: (UnsafePointer<Float>, UnsafePointer<Float>, Int) -> Void) throws -> Bool {
        let step = config.step, fade = config.fade
        guard pendL.count >= step else { return false }
        let t0 = CFAbsoluteTimeGetCurrent()
        // Slide the window by `step`.
        histL.withUnsafeMutableBufferPointer { h in
            h.baseAddress!.update(from: h.baseAddress! + step, count: chunk - step)
            pendL.withUnsafeBufferPointer { (h.baseAddress! + chunk - step).update(from: $0.baseAddress!, count: step) }
        }
        histR.withUnsafeMutableBufferPointer { h in
            h.baseAddress!.update(from: h.baseAddress! + step, count: chunk - step)
            pendR.withUnsafeBufferPointer { (h.baseAddress! + chunk - step).update(from: $0.baseAddress!, count: step) }
        }
        pendL.removeFirst(step); pendR.removeFirst(step)

        histL.withUnsafeBufferPointer { l in histR.withUnsafeBufferPointer { r in
            spec.analyze(left: l.baseAddress!, right: r.baseAddress!, into: model.inputPointer)
        } }
        let t1 = CFAbsoluteTimeGetCurrent()
        do {
            try model.run { view in
                let t2 = CFAbsoluteTimeGetCurrent()
                lastModelTime = t2 - t1
                outL.withUnsafeMutableBufferPointer { l in outR.withUnsafeMutableBufferPointer { r in
                    spec.synthesize(view, left: l.baseAddress!, right: r.baseAddress!)
                } }
            }
        } catch {
            // A failed model call (rare Core ML error) becomes one silent step, so the stream keeps its timing.
            for i in 0..<chunk { outL[i] = 0; outR[i] = 0 }
            modelFailures += 1
        }

        // Segment [start, start + step + fade) of the window.
        let start = chunk - MDX.trim - config.rightContext - step
        let k = MDX.compensate
        var segL = [Float](repeating: 0, count: step + fade), segR = segL
        let music = stem == .music
        for i in 0..<(step + fade) {
            var l = outL[start + i] * k, r = outR[start + i] * k
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
}
