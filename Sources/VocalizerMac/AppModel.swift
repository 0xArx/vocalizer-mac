import AppKit
import Combine
import CoreAudio
import ServiceManagement
import VocalizerCore

enum Mode: String, CaseIterable, Identifiable {
    case live, balanced, quality, supreme, ultra
    var id: String { rawValue }
    /// nil for Supreme until its model is downloaded.
    var separation: VocalizerEngine.Separation? {
        switch self {
        case .ultra: .deepFilter
        case .live: .mdx(.live)
        case .balanced: .mdx(.balanced)
        case .quality: .mdx(.quality)
        case .supreme: SupremeModel.files().map { .roformer(model: $0.model, info: $0.info) }
        }
    }
    var title: String {
        switch self {
        case .ultra: "Speech"
        case .live: "Fast"
        case .balanced: "Balanced"
        case .quality: "Clean"
        case .supreme: "Best"
        }
    }
    var symbol: String {
        switch self {
        case .ultra: "person.wave.2.fill"
        case .live: "bolt.fill"
        case .balanced: "slider.horizontal.3"
        case .quality: "sparkles"
        case .supreme: "wand.and.stars"
        }
    }
    /// Algorithmic delay in ms (before buffering).
    var latencyMs: Double {
        switch self {
        case .ultra: Double(DeepFilterSeparator.modelDelay + 480) / 48
        case .live: SeparatorConfig.live.latencyMs
        case .balanced: SeparatorConfig.balanced.latencyMs
        case .quality: SeparatorConfig.quality.latencyMs
        case .supreme: Double(1024 + RoformerConfig.supreme.rightContext + RoformerConfig.supreme.step) / 44.1
        }
    }
    func hint(delaySeconds d: Double) -> String {
        let delay = d < 1 ? String(format: "%.1f s", d) : String(format: "%.0f s", d.rounded())
        switch self {
        case .ultra: return "For talks and calls. Also removes singing. \(delay) behind."
        case .live: return "For everyday videos. \(delay) behind."
        case .balanced: return "A little cleaner than Fast. \(delay) behind."
        case .quality: return "Cleaner voices, for music apps. \(delay) behind."
        case .supreme: return "The cleanest voices. \(delay) behind, videos wait for it."
        }
    }
    /// Expected capture-to-speaker delay: model delay + safety buffer + ~35 ms of audio IO.
    func expectedDelayMs(sync: Bool) -> Double {
        let buffer = sync ? syncJitterMs : (self == .supreme ? 2700 : self == .quality ? 250 : self == .ultra ? 25 : 100)
        return latencyMs + buffer + 35
    }
    /// Extra buffering in sync mode, where the delay is hidden from video anyway.
    /// (Supreme measures its own on load, ~2.7 s; this is the estimate shown before it runs.)
    var syncJitterMs: Double { self == .supreme ? 2700 : self == .quality ? 300 : self == .ultra ? 80 : 200 }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var enabled = false {
        didSet {
            if enabled != oldValue { apply() }
            // Remember it, so it comes back on after a restart (with Open at login).
            if !restoring && !AppModel.testing { UserDefaults.standard.set(enabled, forKey: "wasOn") }
        }
    }
    private var restoring = false
    /// Diagnostic runs (--selftest, --snapshot, ...) must not change the user's saved settings.
    nonisolated static let testing = CommandLine.arguments.contains { $0.hasPrefix("--") }
    @Published var openAtLogin = SMAppService.mainApp.status == .enabled {
        didSet {
            guard openAtLogin != oldValue else { return }
            do {
                if openAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                self.error = "Open at login: \(error.localizedDescription)"
                openAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }
    @Published var sourceID = AudioSource.all.id { didSet { if sourceID != oldValue, enabled { apply() } } }
    @Published var mode: Mode = .live {
        // Supreme without its model yet: keep playing in the previous mode until the download finishes.
        didSet { if mode != oldValue, enabled, mode.separation != nil { apply() } }
    }
    @Published var keepMusic = false { didSet { engine.stem = keepMusic ? .music : .vocals } }
    /// Route all audio through the Vocalizer virtual device, which reports our delay so video players
    /// hold the picture back by the same amount (lip sync).
    @Published var syncVideo = UserDefaults.standard.object(forKey: "syncVideo") as? Bool ?? true {
        didSet {
            if !AppModel.testing { UserDefaults.standard.set(syncVideo, forKey: "syncVideo") }
            if syncVideo != oldValue, enabled { apply() }
        }
    }
    @Published private(set) var driverInstalled = AudioProcesses.vocalizerDevice() != nil
    @Published private(set) var reportedLatencyMs = 0.0
    // MARK: Supreme model download

    @Published private(set) var supremeReady = SupremeModel.files() != nil
    @Published private(set) var supremeProgress: Double?

    func downloadSupreme() {
        guard supremeProgress == nil else { return }
        supremeProgress = 0
        error = nil
        SupremeModel.download(progress: { [weak self] p in self?.supremeProgress = p }) { [weak self] err in
            guard let self else { return }
            self.supremeProgress = nil
            if let err { self.error = "Supreme download: \(err.localizedDescription)"; return }
            self.supremeReady = true
            self.status = "Preparing Supreme…"
            // Load + warm up on the GPU off the main thread, then (re)start in Supreme.
            if let files = SupremeModel.files() {
                Task.detached { [engine] in
                    try? engine.preloadRoformer(model: files.model, info: files.info)
                    await MainActor.run { if self.enabled && self.mode == .supreme { self.apply() } }
                }
            }
        }
    }

    /// Modes this build can run (Speech needs the optional DeepFilterNet library).
    /// (Balanced is kept for saved settings but not offered: it was barely different from Fast.)
    let availableModes: [Mode] = Mode.allCases.filter { $0 != .balanced && ($0 != .ultra || AppModel.bundledDeepFilter() != nil) }
    /// Engine starts since launch (diagnostics: should not climb while playing).
    private(set) var starts = 0
    var syncActive: Bool { syncVideo && driverInstalled }
    @Published private(set) var sources: [AudioSource] = []
    @Published private(set) var stats = EngineStats()
    @Published private(set) var status = "Loading model…"
    @Published private(set) var error: String?
    @Published private(set) var ready = false
    @Published private(set) var silentFor = 0.0

    let engine = VocalizerEngine(modelURLs: AppModel.bundledModels(), deepFilter: AppModel.bundledDeepFilter())
    private var timer: Timer?
    private var lastHeard = Date()
    private var outputListener: AudioObjectPropertyListenerBlock?

    nonisolated static func bundledDeepFilter() -> (library: URL, model: URL)? {
        guard let lib = Bundle.main.privateFrameworksURL?.appendingPathComponent("libdf.dylib"),
              let model = Bundle.main.url(forResource: "DeepFilterNet3_onnx.tar", withExtension: "gz"),
              FileManager.default.fileExists(atPath: lib.path) else { return nil }
        return (lib, model)
    }

    nonisolated static func bundledModels() -> [Int: URL] {
        var out: [Int: URL] = [:]
        for f in [32, 64, 256] {
            if let url = Bundle.main.url(forResource: "MDXVocals\(f)", withExtension: "mlmodelc")
                ?? Bundle.main.url(forResource: "MDXVocals\(f)", withExtension: "mlpackage") { out[f] = url }
        }
        return out
    }

    init() {
        refreshSources()
        Task.detached(priority: .userInitiated) { [engine] in
            do {
                try engine.preload()
                await MainActor.run {
                    self.ready = true
                    self.status = "Ready"
                    // Resume where the user left off (not in the test modes, which drive `enabled` themselves).
                    if !AppModel.testing && UserDefaults.standard.bool(forKey: "wasOn") {
                        self.restoring = true
                        self.enabled = true
                        self.restoring = false
                    }
                }
            } catch {
                await MainActor.run { self.error = "Model failed to load: \(error.localizedDescription)" }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // Follow the default output device (headphones plugged in, AirPods, etc.).
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.defaultOutputChanged() }
        }
        outputListener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, block)

        // If we quit or crashed while routing through the Vocalizer device, give the speakers back.
        // (Not in diagnostic runs: the real app may be running and routing right now.)
        if !AppModel.testing { restoreRealOutput() }
        installSignalHandlers()
        startWatchdog()
        if !AppModel.testing {
            hotKey = HotKey { [weak self] in
                guard let self, self.ready else { return }
                self.enabled.toggle()
            }
            updaterSink = updater.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            updater.checkSoon()
            DispatchQueue.main.async { WelcomeWindow.showIfFirstLaunch(model: self) }
        }

        // Volume keys / mute act on the Vocalizer device while routed: pass them on to the real speakers.
        for sel in [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute] {
            if let v = AudioProcesses.vocalizerDevice() {
                var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
                let b: AudioObjectPropertyListenerBlock = { [weak self] _, _ in Task { @MainActor in self?.vocalizerVolumeChanged() } }
                listeners.append(b)
                AudioObjectAddPropertyListenerBlock(v, &a, .main, b)
            }
        }
        // Speakers unplugged / plugged in: if the real output disappears, move to the next one.
        var devicesAddr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let devicesBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in Task { @MainActor in self?.devicesChanged() } }
        listeners.append(devicesBlock)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devicesAddr, .main, devicesBlock)
        // After sleep the audio hardware may have been reset.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Fresh models after sleep (see VocalizerEngine.reloadModels), then restart if on.
                self.engine.stop()
                self.engine.reloadModels()
                if self.enabled { self.apply() }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.engine.stop()
                self?.restoreRealOutput()
            }
        }
    }

    private var listeners: [AudioObjectPropertyListenerBlock] = []
    private var hotKey: HotKey?
    let updater = Updater()
    private var updaterSink: AnyCancellable?
    private var activeRealUID: String?

    // MARK: volume pass-through (sync mode)

    /// Shows the real speakers' level on the Vocalizer device (so the volume slider starts where it was).
    private func mirrorVolumeFromReal(_ real: AudioDeviceID) {
        guard let v = AudioProcesses.vocalizerDevice() else { return }
        syncingVolume = true
        if let vol = AudioProcesses.volume(real) { AudioProcesses.setVolume(v, vol) }
        if let m = AudioProcesses.isMuted(real) { AudioProcesses.setMuted(v, m) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.syncingVolume = false }
        engine.outputGain = 1
    }
    private var syncingVolume = false

    private func vocalizerVolumeChanged() {
        guard enabled, syncActive, !syncingVolume, let v = AudioProcesses.vocalizerDevice(),
              let uid = activeRealUID, let real = AudioProcesses.device(uid: uid) else { return }
        let vol = AudioProcesses.volume(v) ?? 1
        let muted = AudioProcesses.isMuted(v) ?? false
        let hw = AudioProcesses.setVolume(real, vol)
        let hwMute = AudioProcesses.setMuted(real, muted)
        // No hardware volume on the speakers: apply it ourselves (roughly the macOS curve).
        engine.outputGain = (hw ? 1 : powf(vol, 3)) * (muted && !hwMute ? 0 : 1)
    }

    /// Output devices seen so far (to tell "plugged in" from "unplugged"), and where we played before.
    private var knownOutputUIDs = Set(AudioProcesses.realOutputs().map(\.uid))
    private var outputHistory: [String] = []

    /// Plugging in headphones / connecting AirPods moves the sound to them, like macOS does; unplugging
    /// goes back to the previous output that is still there.
    private func devicesChanged() {
        let outputs = AudioProcesses.realOutputs()
        let current = Set(outputs.map(\.uid))
        let added = outputs.filter { !knownOutputUIDs.contains($0.uid) }
        knownOutputUIDs = current
        refreshOutputs()
        guard enabled, syncActive else { return }
        if let new = added.last {
            NSLog("Vocalizer: \(new.name) connected, playing there")
            choose(output: new.uid)
        } else if let uid = activeRealUID, !current.contains(uid) {
            while let previous = outputHistory.popLast() {
                if current.contains(previous) { realOutputUID = previous; break }
            }
            if let uid = realOutputUID, !current.contains(uid) { realOutputUID = nil }
            NSLog("Vocalizer: output \(uid) disappeared, back to \(realOutputUID ?? "default")")
            apply()
        }
    }

    // MARK: output picker

    @Published private(set) var outputs: [OutputChoice] = []
    @Published private(set) var currentOutputUID: String?
    struct OutputChoice: Identifiable, Hashable { let id: String; let name: String }

    func refreshOutputs() {
        let list = AudioProcesses.realOutputs().map { OutputChoice(id: $0.uid, name: $0.name) }
        if list != outputs { outputs = list }
        if syncActive && enabled {
            currentOutputUID = activeRealUID
        } else if let d = try? AudioProcesses.defaultOutputDevice(), let uid = AudioProcesses.uid(of: d),
                  !uid.lowercased().hasPrefix("vocalizer") {
            currentOutputUID = uid
        } else {
            currentOutputUID = realOutputUID
        }
    }

    /// Plays on this output (sync: our real output; otherwise the system default).
    func choose(output uid: String) {
        guard let dev = AudioProcesses.device(uid: uid) else { return }
        if enabled && syncActive {
            guard uid != activeRealUID else { return }
            realOutputUID = uid
            apply()
        } else {
            setDefaultOutput(dev)
            realOutputUID = uid
        }
        currentOutputUID = uid
    }

    /// A copy of ourselves that waits for this process to exit and restores the speakers if we could not.
    private func startWatchdog() {
        guard !CommandLine.arguments.contains(where: { $0.hasPrefix("--") }), let exe = Bundle.main.executableURL else { return }
        let p = Process()
        p.executableURL = exe
        p.arguments = ["--watchdog", String(getpid())]
        try? p.run()
    }

    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    self?.engine.stop()
                    self?.restoreRealOutput()
                }
                exit(0)
            }
            src.resume()
            signalSources.append(src)
        }
    }
    private var signalSources: [DispatchSourceSignal] = []

    // MARK: real output device (the speakers/headphones the vocals play on in sync mode)

    private var realOutputUID: String? {
        get { UserDefaults.standard.string(forKey: "realOutputUID") }
        set { UserDefaults.standard.set(newValue, forKey: "realOutputUID") }
    }

    private func realOutput() -> AudioDeviceID? {
        let vocalizer = AudioProcesses.vocalizerDevice()
        if let d = try? AudioProcesses.defaultOutputDevice(), d != vocalizer { return d }
        if let uid = realOutputUID, let d = AudioProcesses.device(uid: uid) { return d }
        let outputs = AudioProcesses.realOutputs()
        // Prefer the Mac's own speakers/headphones over anything else.
        return (outputs.first { $0.uid.contains("BuiltIn") } ?? outputs.first)?.id
    }

    private func restoreRealOutput() {
        AudioProcesses.setVocalizerName("Vocalizer")
        guard let v = AudioProcesses.vocalizerDevice(), (try? AudioProcesses.defaultOutputDevice()) == v,
              let real = realOutput() else { return }
        setDefaultOutput(real)
    }

    /// Our own default-output switches also fire the listener; ignore them for a moment.
    private var ignoreOutputChangesUntil = Date.distantPast

    private func setDefaultOutput(_ device: AudioDeviceID) {
        ignoreOutputChangesUntil = Date().addingTimeInterval(1.5)
        try? AudioProcesses.setDefaultOutput(device)
    }

    private func defaultOutputChanged() {
        guard enabled, Date() > ignoreOutputChangesUntil else { return }
        if syncActive {
            // Ignore our own switch to the Vocalizer device; any other choice becomes the new real output.
            if let d = try? AudioProcesses.defaultOutputDevice(), d == AudioProcesses.vocalizerDevice() { return }
        }
        apply()
    }

    /// Tells apps our delay, once per start. It is fixed while running (the engine holds it exactly), so
    /// video never has to re-sync. Apps read it when they (re)open the device, so after a mode change
    /// (device already selected) bounce the default output once.
    private func reportLatency(bounce: Bool) {
        guard let v = AudioProcesses.vocalizerDevice(), let real = realOutput() else { return }
        let s = engine.stats
        let ms = s.totalLatencyMs
        // Same delay as players already use (restart after wake, speakers with near-identical latency):
        // no need to make them reopen, which would cause a visible hiccup. 25 ms is below what lip sync shows.
        let previous = reportedLatencyMs
        let bounce = bounce && (previous == 0 || abs(ms - previous) > 25)
        let rate = (try? CA_nominalRate(v)) ?? 48_000
        try? AudioProcesses.setVocalizerLatency(frames: Int(ms / 1000 * rate))
        reportedLatencyMs = ms
        let current = try? AudioProcesses.defaultOutputDevice()
        if current == v && bounce {
            // Players only re-read the delay when they reopen the device. An instant away-and-back switch
            // is coalesced by Chrome (measured: video stayed on the old delay), so stay on the real
            // speakers long enough for them to reopen. It is silent: every app is muted by our tap and
            // its audio still goes through Vocalizer either way.
            setDefaultOutput(real)
            let hold = ProcessInfo.processInfo.environment["VOCALIZER_BOUNCE_MS"].flatMap(Double.init) ?? 800
            ignoreOutputChangesUntil = Date().addingTimeInterval(hold / 1000 + 1.5)
            DispatchQueue.main.asyncAfter(deadline: .now() + hold / 1000) { [weak self] in
                guard let self, self.enabled, self.syncActive else { return }
                self.setDefaultOutput(v)
            }
        } else if current != v {
            setDefaultOutput(v)
        }
    }

    var source: AudioSource {
        if sourceID == AudioSource.all.id { return .all }
        return sources.first { $0.id == sourceID } ?? .all
    }

    func refreshSources() {
        let fresh = AudioProcesses.list()
        if fresh != sources { sources = fresh }
    }

    // MARK: switching feedback

    /// Mode whose model is loading in the background (the previous mode keeps playing meanwhile).
    @Published private(set) var preparing: Mode?
    /// Until when videos are holding their picture for our delay (after a switch, or when sound starts).
    @Published private(set) var catchUpUntil: Date?
    private var heardSoundAt: Date?, silentSince: Date?

    var catchUpSeconds: Int? {
        guard let until = catchUpUntil else { return nil }
        let left = until.timeIntervalSinceNow
        return left > 0.2 ? Int(left.rounded(.up)) : nil
    }

    /// Long delays (Best, Clean) make videos wait visibly: show a countdown while they do.
    private func startCatchUp() {
        let delay = engine.stats.totalLatencyMs / 1000
        guard enabled, delay >= 1 else { return }
        catchUpUntil = Date().addingTimeInterval(delay)
        catchUpTotal = delay
    }
    private(set) var catchUpTotal = 1.0

    /// 0...1 progress through the current wait, for the bar under the header.
    var catchUpProgress: Double? {
        guard let until = catchUpUntil, catchUpSeconds != nil else { return nil }
        return min(1, max(0, 1 - until.timeIntervalSinceNow / catchUpTotal))
    }

    private func apply() {
        driverInstalled = AudioProcesses.vocalizerDevice() != nil
        defer { refreshOutputs() }
        // Best's model takes a few seconds to load and warm up on the GPU: do it off the main thread and keep
        // the current mode playing until it is ready, then come back here.
        if enabled, ready, mode == .supreme, let files = SupremeModel.files(), !engine.isRoformerLoaded(files.model) {
            if preparing != .supreme {
                preparing = .supreme
                Task.detached(priority: .userInitiated) { [engine] in
                    var message: String?
                    do { try engine.preloadRoformer(model: files.model, info: files.info) } catch { message = error.localizedDescription }
                    let failure = message
                    await MainActor.run {
                        self.preparing = nil
                        if let failure { self.error = "Best mode: \(failure)"; return }
                        if self.enabled && self.mode == .supreme { self.apply() }
                    }
                }
            }
            return
        }
        guard enabled else {
            engine.stop()
            restoreRealOutput()
            AudioProcesses.setVocalizerName("Vocalizer")
            reportedLatencyMs = 0
            status = ready ? "Off" : status
            stats = engine.stats
        // Sound starting after a pause (a new video, play, or a seek): videos hold their picture for our
        // delay, so count it down.
        // (Paused players send digital silence; real quiet passages stay above -80 dB.)
        if stats.running && stats.inputPeak > 1e-4 {
            if let since = silentSince, Date().timeIntervalSince(since) > 1.0 { startCatchUp() }
            silentSince = nil
        } else if silentSince == nil {
            silentSince = Date()
        }
            return
        }
        guard ready else { status = "Loading model…"; return }
        error = nil
        refreshSources()
        do {
            if syncActive {
                guard let real = realOutput() else { throw CAError(-1, "no output device to play on") }
                realOutputUID = AudioProcesses.uid(of: real)
                if let old = activeRealUID, old != realOutputUID {
                    outputHistory.removeAll { $0 == old }
                    outputHistory.append(old)
                }
                activeRealUID = realOutputUID
                // Control Center / Sound settings show where the sound really goes.
                AudioProcesses.setVocalizerName("Vocalizer (\(AudioProcesses.name(of: real) ?? "speakers"))")
                mirrorVolumeFromReal(real)
                // Sync mode: latency is hidden from video, so buffer generously (no dropouts).
                let wasRouted = (try? AudioProcesses.defaultOutputDevice()) == AudioProcesses.vocalizerDevice()
                guard let separation = mode.separation else { throw CAError(-1, "Download the Supreme model first") }
                try engine.start(source: .virtualDevice, separation: separation,
                                 jitterMs: mode.syncJitterMs, outputDevice: real, fixedDelay: true)
                reportLatency(bounce: wasRouted)
            } else {
                restoreRealOutput()
                guard let separation = mode.separation else { throw CAError(-1, "Download the Supreme model first") }
                try engine.start(source: source, separation: separation)
            }
            lastHeard = Date()
            starts += 1
            status = "On"
            startCatchUp()
        } catch {
            self.error = error.localizedDescription
            NSLog("Vocalizer: start failed: \(error)")
            enabled = false
        }
    }

    /// Installs the bundled Vocalizer.driver (asks for the admin password via the macOS dialog).
    func installDriver() {
        guard let driver = Bundle.main.url(forResource: "Vocalizer", withExtension: "driver") else {
            error = "Driver missing from the app bundle"; return
        }
        let dest = "/Library/Audio/Plug-Ins/HAL/Vocalizer.driver"
        let cmd = "rm -rf '\(dest)' && cp -R '\(driver.path)' '\(dest)' && chown -R root:wheel '\(dest)' && killall coreaudiod"
        let script = "do shell script \"\(cmd)\" with administrator privileges with prompt \"Vocalizer wants to install its audio device so video stays in sync.\""
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
        if let err { error = (err[NSAppleScript.errorMessage] as? String) ?? "Install cancelled"; return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.driverInstalled = AudioProcesses.vocalizerDevice() != nil
            if self?.enabled == true { self?.apply() }
        }
    }

    private var ticks = 0

    private func tick() {
        // Keep the Source list current (apps that start or stop playing) without a refresh button.
        ticks += 1
        if ticks % 4 == 0 { refreshSources() }
        if !ready { return }
        if enabled && !engine.stats.running { apply() }
        stats = engine.stats
        // Sound starting after a pause (a new video, play, or a seek): videos hold their picture for our
        // delay, so count it down.
        // (Paused players send digital silence; real quiet passages stay above -80 dB.)
        if stats.running && stats.inputPeak > 1e-4 {
            if let since = silentSince, Date().timeIntervalSince(since) > 1.0 { startCatchUp() }
            silentSince = nil
        } else if silentSince == nil {
            silentSince = Date()
        }
        if stats.running {
            if stats.inputPeak > 1e-4 { lastHeard = Date() }
            silentFor = Date().timeIntervalSince(lastHeard)
        } else {
            silentFor = 0
        }
    }
}

private func CA_nominalRate(_ device: AudioDeviceID) throws -> Double {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                          mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var rate: Float64 = 0
    var size = UInt32(MemoryLayout<Float64>.size)
    let err = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &rate)
    guard err == noErr else { throw CAError(err, "nominal rate") }
    return rate
}
