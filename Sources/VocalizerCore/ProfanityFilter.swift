// Optional swear-word filter. Adds no delay of its own: it listens to the audio the moment it is captured and
// mutes words inside the delay the mode already has (Clean holds the sound longer while it's on; Best ~7 s).
//
// Apple's on-device SpeechTranscriber (macOS 26+) transcribes the captured mix (accurate even with music
// behind the voice). With etiquette replacements on, it masks profanity as "****"; a short list adds milder
// words it leaves alone. Only FINAL results are used: they carry each word's own time (measured within about
// 0.1-0.3 s of the true word, usually a little early) and arrive 1.4-3 s after the word on an M-series Mac.
// Quick (volatile) results have no word times; mutes placed from them had to cover ~1.5 s and cut the words
// around the swear word, so they are no longer used. A word whose exact time arrives after it has played is
// missed (counted as late); `arrivals` records how late results come so the app can hold the sound long enough.
// Measure with tools/make_swear_fixture.py (exact word times) + tools/analyze_profanity.py.

import AVFoundation
import CRing
import Foundation
import Speech

/// Words the etiquette filter does not mask (it covers the strong ones itself).
public enum ProfanityWords {
    public static let exact: Set<String> = [
        "hell", "damn", "damned", "dammit", "goddamn", "goddamned", "goddammit", "crap", "crappy", "bastard",
        "bastards", "ass", "asses", "asshole", "assholes", "arse", "arsehole", "dick", "dicks", "piss", "pissed",
        "prick", "slut", "sluts", "whore", "whores", "twat", "wanker", "bollocks", "cock", "cunt", "bitch",
        "bitches", "bitchin", "nigga", "niggas", "nigger", "fag", "faggot", "retard", "hoe", "hoes", "thot",
    ]
    public static let prefixes = ["fuck", "fuk", "shit", "motherf", "bitch", "bullshit", "dumbass", "jackass"]

    public static func isProfane(_ raw: String) -> Bool {
        if raw.contains("*") { return true } // masked by the transcriber's etiquette replacements
        let w = raw.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        guard !w.isEmpty else { return false }
        return exact.contains(w) || prefixes.contains { w.hasPrefix($0) }
    }
}

@available(macOS 26.0, iOS 26.0, *)
public final class ProfanityFilter: @unchecked Sendable {
    public private(set) var wordsFound = 0
    /// Diagnostics: buffers handed to the recognizer, results back, and the latest text.
    public private(set) var buffersFed = 0, buffersDropped = 0, resultsSeen = 0
    public private(set) var lastText = ""
    private var firstBuffer = true
    /// Audio waiting to fill the next 100 ms block. The recognizer only keeps its clock exact for whole blocks:
    /// fed odd-sized small buffers (Clean hands over ~12 ms at a time) it lost a little time on each one, and
    /// after 25 s it placed words up to 1 s too early, so every mute missed or cut the words before.
    private var block: AVAudioPCMBuffer?
    /// Capture index of the very first frame handed to the recognizer (its clock's zero).
    private var firstFrame: Int64 = -1
    /// Diagnostics: buffers the recognizer's input queue threw away because it fell behind.
    public private(set) var queueDrops = 0
    /// The newest captured frame handed to the recognizer (to measure how late results arrive).
    private var latestFrame: Int64 = 0
    /// How many seconds after each swear word its exact time arrived (newest last, up to 50).
    public private(set) var arrivals: [Double] = [] { didSet { if arrivals.count > 50 { arrivals.removeFirst(arrivals.count - 50) } } }
    /// Diagnostics: every mute placed, in capture seconds, with the word.
    public private(set) var eventLog: [String] = [] { didSet { if eventLog.count > 50 { eventLog.removeFirst(eventLog.count - 50) } } }
    public private(set) var anchorFrame: Int64 = -1
    private let inputRate: Double
    private let queue: OpaquePointer
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzer: SpeechAnalyzer?
    private var resultsTask: Task<Void, Never>?
    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?
    private var inFormat: AVAudioFormat

    /// `queue` is the engine's CMuteQueue; events are in input-frame units at `inputRate`.
    public init(inputRate: Double, queue: OpaquePointer) {
        self.inputRate = inputRate
        self.queue = queue
        inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 1, interleaved: false)!
    }

    public static var isSupported: Bool { SpeechTranscriber.isAvailable }

    /// Sets up the recognizer (downloads Apple's English speech model the first time).
    public func start(locale: Locale = Locale(identifier: "en_US")) async throws {
        let loc = await SpeechTranscriber.supportedLocale(equivalentTo: locale) ?? locale
        let transcriber = SpeechTranscriber(locale: loc,
                                            transcriptionOptions: [.etiquetteReplacements],
                                            reportingOptions: [.volatileResults, .fastResults],
                                            attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        guard let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw NSError(domain: "ProfanityFilter", code: 1, userInfo: [NSLocalizedDescriptionKey: "no speech audio format"])
        }
        analyzerFormat = fmt
        converter = AVAudioConverter(from: inFormat, to: fmt)
        converter?.primeMethod = .none
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(400))
        continuation = cont
        try await analyzer.start(inputSequence: stream)
        self.analyzer = analyzer
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results { self?.handle(result) }
            } catch {}
        }
    }

    public func stop() {
        continuation?.finish()
        continuation = nil
        resultsTask?.cancel()
        let a = analyzer
        analyzer = nil
        Task { await a?.cancelAndFinishNow() }
    }

    /// Worker thread: the captured stereo audio, `startFrame` = its input-frame index.
    public func feed(left: UnsafePointer<Float>, right: UnsafePointer<Float>, count: Int, startFrame: Int64) {
        guard let cont = continuation, let converter, let analyzerFormat, count > 0,
              let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(count)) else { return }
        input.frameLength = AVAudioFrameCount(count)
        let m = input.floatChannelData![0]
        for i in 0..<count { m[i] = 0.5 * (left[i] + right[i]) }
        let cap = AVAudioFrameCount(Double(count) * analyzerFormat.sampleRate / inputRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: cap) else { return }
        var fed = false
        _ = converter.convert(to: out, error: nil) { _, st in
            if fed { st.pointee = .noDataNow; return nil }
            fed = true; st.pointee = .haveData; return input
        }
        latestFrame = startFrame + Int64(count)
        if firstFrame < 0 { firstFrame = startFrame }
        guard out.frameLength > 0 else { buffersDropped += 1; return }
        // Copy into 100 ms blocks and hand on only full ones.
        let blockFrames = AVAudioFrameCount(analyzerFormat.sampleRate / 10)
        var done: AVAudioFrameCount = 0
        while done < out.frameLength {
            if block == nil { block = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: blockFrames) }
            guard let b = block else { return }
            let n = min(blockFrames - b.frameLength, out.frameLength - done)
            // Byte copy: the recognizer's format may be integer or float, interleaved or not.
            let bpf = Int(analyzerFormat.streamDescription.pointee.mBytesPerFrame)
            let from = UnsafeMutableAudioBufferListPointer(out.mutableAudioBufferList)
            let to = UnsafeMutableAudioBufferListPointer(b.mutableAudioBufferList)
            for i in 0..<min(from.count, to.count) {
                guard let s = from[i].mData, let d = to[i].mData else { return }
                (d + Int(b.frameLength) * bpf).copyMemory(from: s + Int(done) * bpf, byteCount: Int(n) * bpf)
            }
            b.frameLength += n
            done += n
            guard b.frameLength == blockFrames else { break }
            block = nil
            // Every block carries its exact capture time (whole 100 ms steps, so times never overlap or round).
            // Under load (Clean shares the Neural Engine with the recognizer) the recognizer's own running clock
            // slipped by up to 1 s in 25 s; with a time on every block it can't lose its place.
            if firstBuffer { firstBuffer = false; anchorFrame = firstFrame }
            let at = firstFrame + Int64(buffersFed) * Int64(inputRate / 10)
            buffersFed += 1
            if case .dropped = cont.yield(AnalyzerInput(buffer: b, bufferStartTime: CMTime(value: at, timescale: CMTimeScale(inputRate)))) { queueDrops += 1 }
        }
    }

    // MARK: results

    private func frames(_ seconds: Double) -> Int64 { Int64(seconds * inputRate) }

    private func push(_ start: Double, _ end: Double, id: Int32, kind: Int32) {
        _ = cmute_push(queue, CMuteEvent(start: frames(start), end: frames(end), id: id, kind: kind))
    }

    /// Padding around the recognizer's word time, in seconds: before, after, and the shortest mute.
    /// Measured against exact word times: the recognizer places a word's start ~0.12 s early (up to 0.38 s) and its
    /// end ~0.1 s early (-0.29..+0.13 s), so the mute starts a little after the reported start and runs past the end. Tunable for tests with VOCALIZER_SWEAR_PAD="before,after,min".
    private static let pad: (before: Double, after: Double, min: Double) = {
        let v = (ProcessInfo.processInfo.environment["VOCALIZER_SWEAR_PAD"] ?? "").split(separator: ",").compactMap { Double($0) }
        return v.count == 3 ? (v[0], v[1], v[2]) : (-0.03, 0.06, 0.3)
    }()

    private func handle(_ result: SpeechTranscriber.Result) {
        resultsSeen += 1
        lastText = String(result.text.characters.suffix(60))
        guard result.resultsFinalizationTime >= result.range.end else { return } // only final results have word times
        let text = result.text
        let now = Double(latestFrame) / inputRate
        for run in text.runs {
            let word = String(text[run.range].characters)
            guard ProfanityWords.isProfane(word) else { continue }
            guard let tr = run.audioTimeRange else { eventLog.append("untimed \(word)"); continue }
            wordsFound += 1
            arrivals.append(now - tr.end.seconds)
            eventLog.append(String(format: "exact %@ %.2f-%.2f (arrived %.2f s after the word)", word,
                                   tr.start.seconds, tr.end.seconds, now - tr.end.seconds))
            // Masked words can come back very short: never mute less than `min`, growing toward the end.
            let a = tr.start.seconds - Self.pad.before
            let b = max(tr.end.seconds + Self.pad.after, a + Self.pad.min)
            push(a, b, id: 0, kind: 0)
        }
    }
}
