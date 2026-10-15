// Streaming stereo sample-rate converter (AVAudioConverter), planar float in and out.

import AVFoundation

public final class StreamResampler {
    public let from: Double, to: Double
    private let converter: AVAudioConverter?
    private let inFormat: AVAudioFormat, outFormat: AVAudioFormat
    public private(set) var outL: [Float] = [], outR: [Float] = []

    public init(from: Double, to: Double) {
        self.from = from; self.to = to
        inFormat = AVAudioFormat(standardFormatWithSampleRate: from, channels: 2)!
        outFormat = AVAudioFormat(standardFormatWithSampleRate: to, channels: 2)!
        if from == to {
            converter = nil
        } else {
            let c = AVAudioConverter(from: inFormat, to: outFormat)!
            c.primeMethod = .none
            c.sampleRateConverterQuality = AVAudioQuality.high.rawValue
            converter = c
        }
    }

    /// Round-trip delay in seconds of `from -> to -> from` conversion, found with an impulse.
    public static func roundTripDelay(rate: Double, via mid: Double) -> Double {
        guard rate != mid else { return 0 }
        let a = StreamResampler(from: rate, to: mid), b = StreamResampler(from: mid, to: rate)
        var out: [Float] = []
        var block = [Float](repeating: 0, count: 512)
        for i in 0..<32 {
            block[0] = i == 0 ? 1 : 0
            a.process(left: block, right: block, count: 512)
            b.process(left: a.outL, right: a.outR, count: a.outL.count)
            out += b.outL
        }
        let peak = out.indices.max { abs(out[$0]) < abs(out[$1]) } ?? 0
        return Double(peak) / rate
    }

    /// Converts `count` frames; the result is in `outL` / `outR` until the next call.
    public func process(left: UnsafePointer<Float>, right: UnsafePointer<Float>, count: Int) {
        outL.removeAll(keepingCapacity: true); outR.removeAll(keepingCapacity: true)
        guard let converter else {
            outL.append(contentsOf: UnsafeBufferPointer(start: left, count: count))
            outR.append(contentsOf: UnsafeBufferPointer(start: right, count: count))
            return
        }
        guard count > 0, let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(count)) else { return }
        input.frameLength = AVAudioFrameCount(count)
        input.floatChannelData![0].update(from: left, count: count)
        input.floatChannelData![1].update(from: right, count: count)
        // The converter hands back at most one output buffer per call: keep pulling until it runs dry.
        var fed = false
        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 4096) else { return }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inStatus in
                if fed { inStatus.pointee = .noDataNow; return nil }
                fed = true
                inStatus.pointee = .haveData
                return input
            }
            let n = Int(output.frameLength)
            outL.append(contentsOf: UnsafeBufferPointer(start: output.floatChannelData![0], count: n))
            outR.append(contentsOf: UnsafeBufferPointer(start: output.floatChannelData![1], count: n))
            if status != .haveData || n == 0 { break }
        }
    }
}
