// End-to-end loopback test of the real system path (needs System Audio Recording permission,
// so it runs inside the app: `open Vocalizer.app --args --selftest <file> <seconds> <mode> <outdir>`).
// Plays the file with afplay, runs VocalizerEngine on afplay (muted), and records two extra
// unmuted taps on one private aggregate device (one clock): afplay's original audio and this
// process's output. tools/analyze_loopback.py then measures the true delay and SDR.

import CoreAudio
import Foundation

public struct LoopbackError: Error { public let message: String }

public enum LoopbackTest {
    public static func run(engine: VocalizerEngine, file: String, seconds: Double, mode: String, outDir: URL,
                           log: (String) -> Void) throws {
        // "sync-live" etc.: route through the Vocalizer virtual device instead of a process tap.
        let sync = mode.hasPrefix("sync-")
        let base = sync ? String(mode.dropFirst(5)) : mode
        let config: SeparatorConfig = ["live": .live, "balanced": .balanced, "quality": .quality][base] ?? .live
        var separation: VocalizerEngine.Separation = base == "ultra" ? .deepFilter : .mdx(config)
        if base == "supreme" {
            guard let f = SupremeModel.files() else { throw LoopbackError(message: "Supreme model not downloaded") }
            separation = .roformer(model: f.model, info: f.info)
        }
        var realOutput: AudioDeviceID?
        if sync {
            guard let v = AudioProcesses.vocalizerDevice() else { throw LoopbackError(message: "Vocalizer device not installed") }
            let current = try AudioProcesses.defaultOutputDevice()
            guard current != v else { throw LoopbackError(message: "default output is already Vocalizer; set your speakers first") }
            realOutput = current
            try AudioProcesses.setDefaultOutput(v)
            usleep(300_000)
        }
        defer { if let realOutput { try? AudioProcesses.setDefaultOutput(realOutput) } }
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        // VOCALIZER_TEST_PROFANITY=1: run with the swear-word filter on.
        let wantFilter = ProcessInfo.processInfo.environment["VOCALIZER_TEST_PROFANITY"] == "1"
        log("swear filter requested: \(wantFilter), supported: \(VocalizerEngine.profanityFilterSupported)")
        if wantFilter { engine.setProfanityFilter(true) }
        try engine.preload()

        // Load Best's model before the source starts, so the test hears it from the first second.
        if case .roformer(let model, let info) = separation { try engine.preloadRoformer(model: model, info: info) }

        // `file` is an audio file to play with afplay, or "app:<bundle id>" to tap a running app.
        var player: Process?
        var source: AudioSource?
        if file.hasPrefix("app:") {
            let id = String(file.dropFirst(4))
            source = AudioProcesses.list().first { $0.id == id }
            guard let source else { throw LoopbackError(message: "\(id) has no audio process (is it playing?)") }
            log("tapping \(source.name): pids \(source.pids), objects \(source.objectIDs)")
        } else {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            p.arguments = [file]
            try p.run()
            player = p
            for _ in 0..<200 {
                if let obj = AudioProcesses.object(for: p.processIdentifier) {
                    source = AudioSource(id: "afplay", name: "afplay", pids: [p.processIdentifier], objectIDs: [obj], isPlaying: true)
                    break
                }
                usleep(10_000)
            }
            guard source != nil else { p.terminate(); throw LoopbackError(message: "afplay never appeared as an audio process") }
            log("afplay pid \(p.processIdentifier), object \(source!.objectIDs[0])")
        }
        let src = source!

        // Recorder: two unmuted taps (afplay original, our own output) in one aggregate device.
        func makeTap(_ objects: [AudioObjectID]) throws -> (AudioObjectID, String) {
            let d = CATapDescription(stereoMixdownOfProcesses: objects)
            d.uuid = UUID(); d.isPrivate = true; d.muteBehavior = .unmuted
            var id = AudioObjectID(kAudioObjectUnknown)
            let err = AudioHardwareCreateProcessTap(d, &id)
            guard err == noErr else { throw NSError(domain: "tap", code: Int(err)) }
            return (id, d.uuid.uuidString)
        }
        guard let me = AudioProcesses.object(for: getpid()) else { log("no process object for self"); throw LoopbackError(message: "failed") }
        let (origTap, origUID) = try makeTap(src.objectIDs)
        let (selfTap, selfUID) = try makeTap([me])
        let outUID = AudioProcesses.uid(of: try AudioProcesses.defaultOutputDevice())!
        var recAgg = AudioObjectID(kAudioObjectUnknown)
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Vocalizer recorder",
            kAudioAggregateDeviceUIDKey: "vocalizer-rec-\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: origUID], [kAudioSubTapUIDKey: selfUID]],
        ]
        var err = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &recAgg)
        guard err == noErr else { throw LoopbackError(message: "recorder aggregate failed \(err)") }

        let lock = NSLock()
        var orig = [Float](), mine = [Float]()
        orig.reserveCapacity(Int(48_000 * seconds * 2.2)); mine.reserveCapacity(Int(48_000 * seconds * 2.2))
        var layout = ""
        var recProc: AudioDeviceIOProcID?
        err = AudioDeviceCreateIOProcIDWithBlock(&recProc, recAgg, nil) { _, input, _, _, _ in
            let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            // The last two input streams are the taps, in list order (original, ours).
            guard ins.count >= 2 else { return }
            let bufs = [ins[ins.count - 2], ins[ins.count - 1]]
            lock.lock(); defer { lock.unlock() }
            if layout.isEmpty { layout = ins.map { "\($0.mNumberChannels)ch/\($0.mDataByteSize)B" }.joined(separator: ", ") }
            for (k, b) in bufs.enumerated() {
                guard let d = b.mData else { continue }
                let ch = Int(b.mNumberChannels), n = Int(b.mDataByteSize) / (4 * max(ch, 1))
                let p = d.assumingMemoryBound(to: Float.self)
                for i in 0..<n {
                    let l = p[i * ch], r = ch > 1 ? p[i * ch + 1] : l
                    if k == 0 { orig.append(l); orig.append(r) } else { mine.append(l); mine.append(r) }
                }
            }
        }
        guard err == noErr else { log("recorder ioproc failed \(err)"); throw LoopbackError(message: "failed") }

        if sync {
            try engine.start(source: .virtualDevice, separation: separation, jitterMs: Double(ProcessInfo.processInfo.environment["VOCALIZER_TEST_JITTER"] ?? "") ?? (base == "supreme" ? 700 : base == "quality" ? 300 : base == "ultra" ? 80 : 200), outputDevice: realOutput)
            let ms = engine.stats.totalLatencyMs
            try AudioProcesses.setVocalizerLatency(frames: Int(ms / 1000 * 48_000))
            if let v = AudioProcesses.vocalizerDevice() {
                log(String(format: "Vocalizer device now reports %u frames output latency (%.0f ms)", AudioProcesses.outputLatencyFrames(v), ms))
            }
        } else {
            try engine.start(source: src, separation: separation)
        }
        err = AudioDeviceStart(recAgg, recProc)
        guard err == noErr else { log("recorder start failed \(err)"); throw LoopbackError(message: "failed") }
        let rate = engine.stats.sampleRate
        log("engine running at \(rate) Hz on \(engine.stats.outputDevice), mode \(mode): \(base == "ultra" ? "DeepFilterNet3" : base == "supreme" ? "MelBand RoFormer" : config.description)")

        let t0 = Date()
        while Date().timeIntervalSince(t0) < seconds {
            usleep(1_000_000)
            let s = engine.stats
            log(String(format: "t=%4.1fs in %.3f out %.3f | latency %.0f ms (pipeline) + %.0f ms (device) | RTF %.3f, step %.1f ms (model %.1f), worst %.1f | underruns %d",
                         s.capturedSeconds, s.inputPeak, s.outputPeak, s.pipelineLatencyMs, s.deviceLatencyMs,
                         s.realTimeFactor, s.stepMs, s.modelMs, s.worstStepMs, s.underruns))
            if s.profanityFilter || s.profanityPreparing || s.profanityError != nil {
                log("  swear filter: \(s.profanityFilter ? "running" : s.profanityPreparing ? "starting" : "error: \(s.profanityError ?? "")"), muted \(s.wordsMuted), late \(s.wordsLate) | \(engine.profanityDebug)")
            }
        }
        let final = engine.stats
        let swearLog = engine.profanityEvents
        for e in swearLog.events { log("  mute " + e) }
        log("  swear clock anchored at capture frame \(swearLog.anchor)")
        AudioDeviceStop(recAgg, recProc)
        engine.stop()
        player?.terminate()
        AudioDeviceDestroyIOProcID(recAgg, recProc!)
        AudioHardwareDestroyAggregateDevice(recAgg)
        AudioHardwareDestroyProcessTap(origTap)
        AudioHardwareDestroyProcessTap(selfTap)

        lock.lock()
        try orig.withUnsafeBytes { try Data($0).write(to: outDir.appendingPathComponent("original.f32")) }
        try mine.withUnsafeBytes { try Data($0).write(to: outDir.appendingPathComponent("output.f32")) }
        let meta: [String: Any] = ["rate": rate, "mode": mode, "file": file, "layout": layout,
                                   "pipelineLatencyMs": final.pipelineLatencyMs, "deviceLatencyMs": final.deviceLatencyMs,
                                   "algorithmicLatencyMs": final.algorithmicLatencyMs, "realTimeFactor": final.realTimeFactor,
                                   "stepMs": final.stepMs, "modelMs": final.modelMs, "worstStepMs": final.worstStepMs,
                                   "underruns": final.underruns, "wordsMuted": final.wordsMuted, "wordsLate": final.wordsLate]
        try JSONSerialization.data(withJSONObject: meta, options: .prettyPrinted).write(to: outDir.appendingPathComponent("meta.json"))
        log("recorded \(orig.count / 2) / \(mine.count / 2) frames, input layout [\(layout)]")
    }
}
