// Optional swear-word filter. Adds no delay: it listens to the audio the moment it is captured and mutes
// words inside the delay Vocalizer already has (Live ~0.4 s, Quality ~1.9 s, Supreme ~7 s).
//
// Apple's on-device SpeechTranscriber (macOS 26+) transcribes the captured mix (accurate even with music
// behind the voice). With etiquette replacements on, it masks profanity as "****"; a short list adds milder
// words it leaves alone. Measured on speech over music:
//   - volatile (fast) results arrive 0.05-0.7 s after a word, but only with a coarse time window,
//   - final results arrive 1.3-2 s after a word, with exact per-word times.
// So: a provisional mute is placed from the volatile result (a window covering where the word can be), then
// replaced by the exact range if the final result arrives before the word plays. Measured on a speech-over-music
// clip with 7 swear words (tools/analyze_profanity.py): Supreme 6/7 muted precisely, Quality 5/7 (wider mutes),
// Live 0/7 (the words play before they are recognized). Misses were words the recognizer misheard.

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
    /// Diagnostics: every mute placed (kind 0 exact, 1 estimated), in capture seconds, with the word.
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
    private var nextID: Int32 = 1
    /// Provisional mutes not yet replaced: id -> input-frame range.
    private var provisional: [Int32: (Int64, Int64)] = [:]
    /// Tracks the volatile text of the current utterance, to find what is new in each update.
    private var volatileStart = CMTime.invalid
    private var placedInUtterance = 0

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
        guard out.frameLength > 0 else { buffersDropped += 1; return }
        buffersFed += 1
        // Only the first buffer carries a time: it anchors the recognizer's clock to the capture counter, and
        // the rest follow contiguously. (Stamping every buffer made rounded, overlapping times, and the
        // recognizer returned nothing at all.)
        if firstBuffer {
            firstBuffer = false
            anchorFrame = startFrame
            cont.yield(AnalyzerInput(buffer: out, bufferStartTime: CMTime(value: startFrame, timescale: CMTimeScale(inputRate))))
        } else {
            cont.yield(AnalyzerInput(buffer: out))
        }
    }

    // MARK: results

    private func frames(_ seconds: Double) -> Int64 { Int64(seconds * inputRate) }

    private func push(_ start: Double, _ end: Double, id: Int32, kind: Int32) {
        _ = cmute_push(queue, CMuteEvent(start: frames(start), end: frames(end), id: id, kind: kind))
    }

    private func handle(_ result: SpeechTranscriber.Result) {
        resultsSeen += 1
        lastText = String(result.text.characters.suffix(60))
        let isFinal = result.resultsFinalizationTime >= result.range.end
        let text = result.text
        if isFinal {
            // Exact words: replace any provisional mutes in this stretch, then mute each word precisely.
            let rs = result.range.start.seconds, re = result.range.end.seconds
            var alreadyCounted = 0
            for (id, r) in provisional where Double(r.1) / inputRate > rs - 0.5 && Double(r.0) / inputRate < re + 0.5 {
                push(0, 0, id: id, kind: 2)
                provisional[id] = nil
                alreadyCounted += 1
            }
            for run in text.runs {
                guard let tr = run.audioTimeRange else { continue }
                let word = String(text[run.range].characters)
                guard ProfanityWords.isProfane(word) else { continue }
                // Count each swear word once: those already caught by an estimate are not counted again.
                if alreadyCounted > 0 { alreadyCounted -= 1 } else { wordsFound += 1 }
                eventLog.append(String(format: "exact %@ %.2f-%.2f (result %.2f-%.2f)", word, tr.start.seconds, tr.end.seconds, rs, re))
                // Recognizer word ranges can be short (masked words especially): pad, and never under 0.35 s.
                // (A word that opens an utterance is often placed slightly late: give the start more room.)
                var a = tr.start.seconds - 0.2, b = tr.end.seconds + 0.12
                if b - a < 0.45 { let mid = (a + b) / 2; a = mid - 0.25; b = mid + 0.2 }
                push(a, b, id: 0, kind: 0)
            }
            volatileStart = .invalid
            placedInUtterance = 0
            return
        }
        // Volatile (quick) results carry no per-word times. Measured on speech over music, a swear word first
        // shows up 0.3-1.0 s (typically ~0.6 s) after it ends, and each word after it in the same text is ~0.3 s
        // later. So: word end ~= range end - 0.6 s - 0.3 s per following word; mute a tight window around that.
        // Each swear word in an utterance is placed once (revised text used to stack repeated mutes).
        if result.range.start != volatileStart {
            volatileStart = result.range.start
            placedInUtterance = 0
        }
        let words = String(text.characters).split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        let swearIndices = words.indices.filter { ProfanityWords.isProfane(words[$0]) }
        guard swearIndices.count > placedInUtterance else { return }
        let rangeEnd = result.range.end.seconds
        for idx in swearIndices.dropFirst(placedInUtterance) {
            let following = words.count - 1 - idx
            // Measured: the word ends 0.1-1.1 s before the range end; cover that whole spread.
            let lastEnd = rangeEnd - 0.1 - 0.3 * Double(following)
            let duration = min(0.7, max(0.3, 0.07 * Double(words[idx].count) + 0.1))
            // Not clamped to the utterance start: the recognizer often opens an utterance after its first word began.
            let a = lastEnd - 1.0 - duration, b = lastEnd + 0.05
            let id = nextID
            nextID += 1
            provisional[id] = (frames(a), frames(b))
            wordsFound += 1
            eventLog.append(String(format: "estimate %@ %.2f-%.2f (range end %.2f, %d words after)", words[idx], a, b, rangeEnd, following))
            push(a, b, id: id, kind: 1)
        }
        placedInUtterance = swearIndices.count
    }
}
