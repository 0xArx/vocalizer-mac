// System-wide music removal: a Core Audio process tap mutes the chosen app(s) and hands us
// their audio; a worker thread separates it with MDX-Net on the Neural Engine; the vocals play
// through the same private aggregate device (tap + default output share one clock, so no drift).
//
//   IO thread (aggregate device)            worker thread
//   tap input ──▶ inRing ───────────────▶  resample → 44.1 kHz → StreamingSeparator (Core ML)
//   output    ◀── outRing ◀──────────────  resample → device rate ◀──┘

import CoreAudio
import CRing
import Foundation

public struct EngineStats {
    public var running = false
    public var sampleRate = 0.0
    public var outputDevice = ""
    /// Capture → playback delay measured from frame counters (includes buffering), in ms.
    public var pipelineLatencyMs = 0.0
    /// Output device + safety offset + IO buffer, reported by Core Audio, in ms.
    public var deviceLatencyMs = 0.0
    public var algorithmicLatencyMs = 0.0
    /// Separation compute time / audio time (lower is better; must stay below 1).
    public var realTimeFactor = 0.0
    public var stepMs = 0.0, worstStepMs = 0.0, modelMs = 0.0
    public var underruns = 0
    public var inputPeak: Float = 0, outputPeak: Float = 0
    public var capturedSeconds = 0.0
    public var totalLatencyMs: Double { pipelineLatencyMs + deviceLatencyMs }
    public init() {}
}

public final class VocalizerEngine {
    private let modelURLs: [Int: URL]
    private var models: [Int: MDXModel] = [:]
    private let modelLock = NSLock()

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var inRing: OpaquePointer?
    private var outRing: OpaquePointer?
    private var worker: Thread?
    private let wake = DispatchSemaphore(value: 0)
    private var separator: Separating?

    // IO-thread state (also read, racily, for stats).
    private var captured: Int64 = 0, consumed: Int64 = 0
    private var holding = false, fadeIn = 256, cushionFrames = 0
    /// Fixed-delay mode (video sync): never grow the delay; after a dropout skip ahead instead.
    private var fixedDelay = false
    private var owed: Int64 = 0
    /// Delay added by underruns since start (frames).
    private var addedDelay: Int64 = 0
    private var primeFrames = 0
    /// 0-based output channels for left/right (equal on a mono device).
    private var stereoLeft = 0, stereoRight = 1
    private var resamplerDelay = 0.0
    private var underruns = 0
    private var inPeak: Float = 0, outPeak: Float = 0
    private var scratchIn = [Float](repeating: 0, count: 16_384)
    private var scratchOut = [Float](repeating: 0, count: 16_384)

    private let statsLock = NSLock()
    private var _stats = EngineStats()
    public var stats: EngineStats {
        statsLock.lock(); defer { statsLock.unlock() }
        var s = _stats
        s.underruns = underruns
        s.inputPeak = inPeak; s.outputPeak = outPeak
        if s.running, s.sampleRate > 0 {
            // Output stream sample k is input sample k - streamDelay, and it plays primeFrames after capture.
            s.pipelineLatencyMs = (Double(primeFrames + Int(addedDelay)) / s.sampleRate + Double(separator?.streamDelay ?? 0) / (separator?.sampleRate ?? MDX.sampleRate)
                + resamplerDelay) * 1000
            s.capturedSeconds = Double(captured) / s.sampleRate
        }
        return s
    }

    private let deepFilterFiles: (library: URL, model: URL)?

    public enum Separation { case mdx(SeparatorConfig), deepFilter, roformer(model: URL, info: URL) }
    private var roformer: (url: URL, sep: RoformerSeparator)?

    /// True when the Supreme model at `model` is loaded and warmed up (starting it is then instant).
    public func isRoformerLoaded(_ model: URL) -> Bool {
        modelLock.lock(); defer { modelLock.unlock() }
        return roformer?.url == model
    }

    /// Loads (and warms up) the Supreme model ahead of time; the engine reuses it.
    public func preloadRoformer(model: URL, info: URL) throws {
        modelLock.lock(); defer { modelLock.unlock() }
        if roformer?.url == model { return }
        roformer = (model, try RoformerSeparator(modelURL: model, infoURL: info))
    }

    /// `modelURLs[frames]` points at MDXVocals<frames>.mlmodelc (or .mlpackage); `deepFilter` at
    /// libdf.dylib and DeepFilterNet3_onnx.tar.gz for the ultra-fast mode.
    public init(modelURLs: [Int: URL], deepFilter: (library: URL, model: URL)? = nil) {
        self.modelURLs = modelURLs
        deepFilterFiles = deepFilter
    }

    /// Drops the loaded models so the next start loads fresh ones. Called after the Mac wakes: Neural Engine
    /// state from before sleep is what Core ML failed on in the field (output memory binding).
    public func reloadModels() {
        modelLock.lock()
        models.removeAll()
        let supreme = roformer.map { ($0.url, $0.sep) }
        roformer = nil
        modelLock.unlock()
        _ = supreme // released here; reloaded on demand (Supreme takes ~3 s)
    }

    /// Loads (and compiles for the Neural Engine) every model up front; takes a few seconds.
    public func preload() throws { for f in modelURLs.keys.sorted() { _ = try model(f) } }

    private func model(_ frames: Int) throws -> MDXModel {
        modelLock.lock(); defer { modelLock.unlock() }
        if let m = models[frames] { return m }
        guard let url = modelURLs[frames] else { throw NSError(domain: "Vocalizer", code: 2, userInfo: [NSLocalizedDescriptionKey: "no \(frames)-frame model"]) }
        let m = try MDXModel(url: url, frames: frames)
        models[frames] = m
        return m
    }

    public var stem: OutputStem = .vocals { didSet { separator?.stem = stem } }
    /// Software output gain (used when the real output has no volume control); ramped in the IO thread.
    public var outputGain: Float = 1
    private var currentGain: Float = 1

    /// Taps `source` (muted), separates and plays the chosen stem. `jitterMs` is extra buffering
    /// that absorbs compute spikes.
    public func start(source: AudioSource, config: SeparatorConfig, jitterMs: Double? = nil,
                      outputDevice: AudioDeviceID? = nil) throws {
        try start(source: source, separation: .mdx(config), jitterMs: jitterMs, outputDevice: outputDevice)
    }

    /// `fixedDelay`: keep the capture-to-playback delay exactly constant (for video sync, where players
    /// were told the delay); otherwise the delay grows a little after a dropout so it stops recurring.
    public func start(source: AudioSource, separation: Separation, jitterMs: Double? = nil,
                      outputDevice: AudioDeviceID? = nil, fixedDelay: Bool = false) throws {
        stop()
        let sep: Separating
        let defaultJitter: Double
        switch separation {
        case .mdx(let config):
            sep = StreamingSeparator(config: config, model: try model(config.frames))
            defaultJitter = config.frames >= 256 ? 250 : 100
        case .deepFilter:
            guard let df = deepFilterFiles else { throw CAError(-1, "DeepFilterNet library not bundled") }
            sep = try DeepFilterSeparator(library: df.library, model: df.model)
            defaultJitter = 25
        case .roformer(let model, let info):
            try preloadRoformer(model: model, info: info)
            let r = roformer!.sep
            r.reset()
            sep = r
            // A GPU call takes ~1.7 s of every 3 s step: the buffer must cover a whole call (with margin).
            defaultJitter = r.recommendedJitterMs
        }
        let ioBufferFrames: UInt32? = { if case .deepFilter = separation { return 256 } else { return nil } }()
        sep.stem = stem
        separator = sep

        // 1. Input: either a process tap (the app's own output is muted while we read it), or the
        //    Vocalizer virtual device's loopback (apps play into it; nothing is audible from it).
        let output = try outputDevice ?? AudioProcesses.defaultOutputDevice()
        guard let outputUID = AudioProcesses.uid(of: output) else { throw CAError(-1, "output device UID") }
        let subDevices: [[String: Any]] = [[kAudioSubDeviceUIDKey: outputUID]]
        var taps: [[String: Any]] = []
        var err: OSStatus = noErr
        // Sync mode: a global tap on every app but us. Apps that play to the Vocalizer device (the default
        // output, which reports our delay so video waits) are caught, and so are apps pinned to a
        // specific speaker. Otherwise a tap on the chosen app(s). The originals are muted.
        let desc: CATapDescription
        let me = AudioProcesses.object(for: getpid()).map { [$0] } ?? []
        if source.isVirtualDevice {
            guard let dev = AudioProcesses.vocalizerDevice() else { throw CAError(-1, "Vocalizer audio device not installed") }
            guard dev != output else { throw CAError(-1, "output device is the Vocalizer device itself") }
            desc = CATapDescription(stereoGlobalTapButExcludeProcesses: me)
        } else if source.isAll {
            desc = CATapDescription(stereoGlobalTapButExcludeProcesses: me)
        } else {
            desc = CATapDescription(stereoMixdownOfProcesses: source.objectIDs)
        }
        desc.muteBehavior = .muted
        desc.uuid = UUID()
        desc.name = "Vocalizer tap"
        desc.isPrivate = true
        err = AudioHardwareCreateProcessTap(desc, &tapID)
        guard err == noErr else { throw CAError(err, "AudioHardwareCreateProcessTap") }
        taps = [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]]

        // 2. Private aggregate device: the real output as the clock master, plus the input.
        let agg: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Vocalizer",
            kAudioAggregateDeviceUIDKey: "vocalizer-\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: subDevices,
            kAudioAggregateDeviceTapListKey: taps,
        ]
        err = AudioHardwareCreateAggregateDevice(agg as CFDictionary, &aggregateID)
        guard err == noErr else { stop(); throw CAError(err, "AudioHardwareCreateAggregateDevice") }

        if var frames = ioBufferFrames {
            var addr = CA.address(kAudioDevicePropertyBufferFrameSize)
            AudioObjectSetPropertyData(aggregateID, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &frames)
        }
        // The speakers' stereo pair (Audio MIDI Setup › Configure Speakers), or 1/2; mono devices get one channel.
        var outChannels = 0
        if let streams = try? CA.getArray(output, kAudioDevicePropertyStreams, AudioStreamID(0)) {
            var scopeAddr = CA.address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
            var size: UInt32 = 0
            AudioObjectGetPropertyDataSize(output, &scopeAddr, 0, nil, &size)
            var outStreams = [AudioStreamID](repeating: 0, count: Int(size) / 4)
            AudioObjectGetPropertyData(output, &scopeAddr, 0, nil, &size, &outStreams)
            for st in outStreams.isEmpty ? streams : outStreams {
                if let f = try? CA.get(st, kAudioStreamPropertyVirtualFormat, AudioStreamBasicDescription()) { outChannels += Int(f.mChannelsPerFrame) }
            }
        }
        var pair: (UInt32, UInt32) = (1, 2)
        var pairAddr = CA.address(kAudioDevicePropertyPreferredChannelsForStereo, scope: kAudioObjectPropertyScopeOutput)
        var pairSize = UInt32(MemoryLayout<(UInt32, UInt32)>.size)
        AudioObjectGetPropertyData(output, &pairAddr, 0, nil, &pairSize, &pair)
        if outChannels <= 1 {
            stereoLeft = 0; stereoRight = 0
        } else {
            stereoLeft = max(0, min(outChannels - 1, Int(pair.0) - 1))
            stereoRight = max(0, min(outChannels - 1, Int(pair.1) - 1))
        }

        let rate = (try? CA.get(aggregateID, kAudioDevicePropertyNominalSampleRate, Float64(0))) ?? 48_000
        let bufferFrames = (try? CA.get(aggregateID, kAudioDevicePropertyBufferFrameSize, UInt32(0))) ?? 512
        let devLatency = (try? CA.get(output, kAudioDevicePropertyLatency, UInt32(0), scope: kAudioObjectPropertyScopeOutput)) ?? 0
        let safety = (try? CA.get(output, kAudioDevicePropertySafetyOffset, UInt32(0), scope: kAudioObjectPropertyScopeOutput)) ?? 0
        var streamLatency: UInt32 = 0
        if let streams = try? CA.getArray(output, kAudioDevicePropertyStreams, AudioStreamID(0)), let first = streams.first {
            streamLatency = (try? CA.get(first, kAudioStreamPropertyLatency, UInt32(0))) ?? 0
        }

        // 3. Rings and priming: playback starts `step + jitter` behind the separated stream.
        let jitter = max(jitterMs ?? defaultJitter, defaultJitter > 1000 ? defaultJitter : 0)
        let stepDev = Double(sep.step) * rate / sep.sampleRate
        let prime = Int(stepDev + jitter / 1000 * rate + Double(bufferFrames))
        primeFrames = prime
        // Plus two IO cycles (tap read, output write); measured end to end within a few ms.
        resamplerDelay = StreamResampler.roundTripDelay(rate: rate, via: sep.sampleRate) + 2 * Double(bufferFrames) / rate
        inRing = cring_create(UInt32(rate * 4))
        outRing = cring_create(UInt32(max(Double(prime) * 2, rate * 4)))
        let zeros = [Float](repeating: 0, count: prime * 2)
        _ = cring_write(outRing, zeros, UInt32(prime))
        captured = 0; consumed = 0; underruns = 0; inPeak = 0; outPeak = 0
        holding = false; fadeIn = 256; addedDelay = 0; owed = 0
        self.fixedDelay = fixedDelay
        cushionFrames = Int(0.04 * rate) // 40 ms extra after each dropout

        statsLock.lock()
        _stats = EngineStats()
        _stats.running = true
        _stats.sampleRate = rate
        _stats.outputDevice = AudioProcesses.name(of: output) ?? "output"
        _stats.algorithmicLatencyMs = Double(sep.streamDelay + sep.step) / sep.sampleRate * 1000
        _stats.deviceLatencyMs = Double(devLatency + safety + streamLatency + bufferFrames) / rate * 1000
        statsLock.unlock()

        // 4. Worker thread.
        let thread = Thread { [weak self] in self?.workLoop(rate: rate, modelRate: sep.sampleRate) }
        thread.name = "Vocalizer separation"
        thread.qualityOfService = .userInteractive
        worker = thread
        thread.start()

        // 5. IO proc.
        err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { [unowned self] _, input, _, output, _ in
            self.io(input: input, output: output)
        }
        guard err == noErr else { stop(); throw CAError(err, "AudioDeviceCreateIOProcIDWithBlock") }
        err = AudioDeviceStart(aggregateID, procID)
        guard err == noErr else { stop(); throw CAError(err, "AudioDeviceStart") }
    }

    public func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
        if let worker {
            worker.cancel()
            wake.signal()
            while !worker.isFinished { usleep(1000) }
        }
        worker = nil
        cring_destroy(inRing); inRing = nil
        cring_destroy(outRing); outRing = nil
        statsLock.lock(); _stats.running = false; statsLock.unlock()
    }

    deinit { stop() }

    // MARK: IO thread (real time: no locks, no allocation)

    private func io(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outs = UnsafeMutableAudioBufferListPointer(output)

        // Input: the tap is the last stream (stereo interleaved, or two mono buffers).
        var frames = 0
        if let last = ins.last, let data = last.mData {
            let ch = Int(last.mNumberChannels)
            frames = Int(last.mDataByteSize) / (4 * max(ch, 1))
            frames = min(frames, scratchIn.count / 2)
            let src = data.assumingMemoryBound(to: Float.self)
            scratchIn.withUnsafeMutableBufferPointer { s in
                if ch == 2 {
                    s.baseAddress!.update(from: src, count: frames * 2)
                } else if ch == 1, ins.count >= 2, let ld = ins[ins.count - 2].mData {
                    let l = ld.assumingMemoryBound(to: Float.self)
                    for i in 0..<frames { s[2 * i] = l[i]; s[2 * i + 1] = src[i] }
                } else {
                    for i in 0..<frames { s[2 * i] = src[i * ch]; s[2 * i + 1] = src[i * ch + min(1, ch - 1)] }
                }
                var peak: Float = 0
                for i in 0..<(frames * 2) { peak = max(peak, abs(s[i])) }
                inPeak = max(inPeak * 0.95, peak)
                _ = cring_write(inRing, s.baseAddress!, UInt32(frames))
            }
            captured += Int64(frames)
            wake.signal()
        }

        // Output: fixed delay behind capture. On an underrun (a slow model call), fade out, then hold
        // silence until a cushion has built up and fade back in: the delay grows a little each time,
        // so it settles at a size that no longer drops out, with no clicks.
        guard let first = outs.first else { return }
        let outCh = Int(first.mNumberChannels)
        let want = min(Int(first.mDataByteSize) / (4 * max(outCh, 1)), scratchOut.count / 2)
        scratchOut.withUnsafeMutableBufferPointer { s in
            let p = s.baseAddress!
            var got = 0
            if fixedDelay && owed > 0 {
                // Catch up on frames we owe from a dropout, so the delay stays what players were told.
                var skip = min(Int(owed), Int(cring_readable(outRing)))
                owed -= Int64(skip)
                while skip > 0 { skip -= Int(cring_read(outRing, p, UInt32(min(skip, want)))) }
                if owed == 0 { fadeIn = 0 }
            }
            if fixedDelay {
                got = owed > 0 ? 0 : Int(cring_read(outRing, p, UInt32(want)))
                if got < want && owed == 0 {
                    let tail = min(got, 64)
                    for i in 0..<tail {
                        let g = Float(tail - i) / Float(tail + 1)
                        p[2 * (got - tail + i)] *= g; p[2 * (got - tail + i) + 1] *= g
                    }
                    if captured > 0 { underruns += 1 }
                }
                if got < want { owed += Int64(want - got) }
            } else if holding {
                if Int(cring_readable(outRing)) >= want + cushionFrames {
                    holding = false
                    fadeIn = 0
                } else {
                    addedDelay += Int64(want)
                }
            }
            if !fixedDelay && !holding {
                got = Int(cring_read(outRing, p, UInt32(want)))
                if got < want {
                    // Fade the tail we did get, then hold.
                    let tail = min(got, 64)
                    for i in 0..<tail {
                        let g = Float(tail - i) / Float(tail + 1)
                        p[2 * (got - tail + i)] *= g; p[2 * (got - tail + i) + 1] *= g
                    }
                    addedDelay += Int64(want - got)
                    holding = true
                    if captured > 0 { underruns += 1 }
                }
            }
            for i in (got * 2)..<(want * 2) { p[i] = 0 }
            if fadeIn < 256 {
                for i in 0..<got where fadeIn < 256 {
                    let g = Float(fadeIn) / 256
                    p[2 * i] *= g; p[2 * i + 1] *= g
                    fadeIn += 1
                }
            }
            let target = outputGain
            if target != 1 || currentGain != 1 {
                let stepGain = (target - currentGain) / Float(max(want, 1))
                for i in 0..<want {
                    currentGain += stepGain
                    p[2 * i] *= currentGain; p[2 * i + 1] *= currentGain
                }
                currentGain = target
            }
            consumed += Int64(want)
            var peak: Float = 0
            for i in 0..<(want * 2) { peak = max(peak, abs(p[i])) }
            outPeak = max(outPeak * 0.95, peak)

            // Write L/R to the device's preferred stereo channels (counted across all output buffers);
            // a mono device gets (L + R) / 2; every other channel gets silence.
            let lc = stereoLeft, rc = stereoRight
            var base = 0
            for buf in outs {
                guard let d = buf.mData else { continue }
                let o = d.assumingMemoryBound(to: Float.self)
                let ch = max(Int(buf.mNumberChannels), 1)
                let n = min(Int(buf.mDataByteSize) / (4 * ch), want)
                memset(d, 0, Int(buf.mDataByteSize))
                for c in 0..<ch {
                    let channel = base + c
                    if channel == lc && channel == rc {
                        for i in 0..<n { o[i * ch + c] = 0.5 * (p[2 * i] + p[2 * i + 1]) }
                    } else if channel == lc {
                        for i in 0..<n { o[i * ch + c] = p[2 * i] }
                    } else if channel == rc {
                        for i in 0..<n { o[i * ch + c] = p[2 * i + 1] }
                    }
                }
                base += ch
            }
        }
    }

    // MARK: worker thread

    private func workLoop(rate: Double, modelRate: Double) {
        let down = StreamResampler(from: rate, to: modelRate)
        let up = StreamResampler(from: modelRate, to: rate)
        var inter = [Float](repeating: 0, count: Int(rate * 4) * 2)
        var l = [Float](), r = [Float](), out = [Float]()
        var computeTime = 0.0, modelTime = 0.0, steps = 0, worst = 0.0
        var audioTime = 0.0
        while !Thread.current.isCancelled {
            _ = wake.wait(timeout: .now() + .milliseconds(100))
            guard let sep = separator, let inRing, let outRing else { continue }
            let n = Int(cring_read(inRing, &inter, UInt32(inter.count / 2)))
            guard n > 0 else { continue }
            l.removeAll(keepingCapacity: true); r.removeAll(keepingCapacity: true)
            for i in 0..<n { l.append(inter[2 * i]); r.append(inter[2 * i + 1]) }
            down.process(left: l, right: r, count: n)
            sep.push(left: down.outL, right: down.outR, count: down.outL.count)
            do {
                while try sep.process(emit: { el, er, k in
                    up.process(left: el, right: er, count: k)
                    let m = up.outL.count
                    out.removeAll(keepingCapacity: true)
                    for i in 0..<m { out.append(up.outL[i]); out.append(up.outR[i]) }
                    _ = cring_write(outRing, out, UInt32(m))
                }) {
                    steps += 1
                    computeTime += sep.lastStepTime
                    modelTime += sep.lastModelTime
                    worst = max(worst * 0.999, sep.lastStepTime)
                    audioTime += Double(sep.step) / sep.sampleRate
                    statsLock.lock()
                    _stats.realTimeFactor = computeTime / audioTime
                    _stats.stepMs = computeTime / Double(steps) * 1000
                    _stats.modelMs = modelTime / Double(steps) * 1000
                    _stats.worstStepMs = worst * 1000
                    statsLock.unlock()
                }
            } catch {
                NSLog("Vocalizer: separation failed: \(error)")
            }
        }
    }
}
