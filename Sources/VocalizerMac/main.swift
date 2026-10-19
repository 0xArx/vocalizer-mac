// Entry point: `--selftest <file> <seconds> <mode> <outdir>` runs the loopback test inside the
// app bundle (so it has the System Audio Recording permission); otherwise the menu bar app.

import AppKit
import SwiftUI
import VocalizerCore

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--selftest"), args.count >= i + 5 {
    let outDir = URL(fileURLWithPath: args[i + 4])
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    var lines: [String] = []
    let log: (String) -> Void = { line in
        print(line)
        lines.append(line)
        try? lines.joined(separator: "\n").write(to: outDir.appendingPathComponent("log.txt"), atomically: true, encoding: .utf8)
    }
    let engine = VocalizerEngine(modelURLs: AppModel.bundledModels(), deepFilter: AppModel.bundledDeepFilter())
    do {
        try LoopbackTest.run(engine: engine, file: args[i + 1], seconds: Double(args[i + 2]) ?? 12, mode: args[i + 3],
                             outDir: outDir, log: log)
        log("done")
        exit(0)
    } catch {
        log("selftest failed: \(error)")
        exit(1)
    }
}
if let i = args.firstIndex(of: "--watchdog"), args.count > i + 1, let parent = pid_t(args[i + 1]) {
    // Safety net started by the app: if it dies without cleaning up (crash, kill -9) while macOS still
    // plays to the Vocalizer device, give the speakers back. Survives `pkill Vocalizer` on purpose.
    for sig in [SIGTERM, SIGINT, SIGHUP] { signal(sig, SIG_IGN) }
    func restore() -> Never {
        usleep(500_000) // let a normal quit restore first
        if let v = AudioProcesses.vocalizerDevice(), (try? AudioProcesses.defaultOutputDevice()) == v {
            let saved = UserDefaults.standard.string(forKey: "realOutputUID").flatMap { AudioProcesses.device(uid: $0) }
            let outputs = AudioProcesses.realOutputs()
            if let real = saved ?? (outputs.first { $0.uid.contains("BuiltIn") } ?? outputs.first)?.id {
                try? AudioProcesses.setDefaultOutput(real)
            }
        }
        AudioProcesses.setVocalizerName("Vocalizer")
        exit(0)
    }
    if kill(parent, 0) != 0 { restore() }
    let src = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .main)
    src.setEventHandler { restore() }
    src.resume()
    dispatchMain()
}
if args.contains("--download-supreme") {
    // Diagnostics: the same download the menu's button does.
    let t0 = Date()
    var last = -1
    SupremeModel.download(progress: { p in
        let pct = Int(p * 100); if pct / 10 != last / 10 { print("download \(pct)%"); last = pct }
    }) { err in
        print(err.map { "failed: \($0.localizedDescription)" } ?? String(format: "done in %.0f s -> %@", Date().timeIntervalSince(t0), SupremeModel.directory.path))
        exit(err == nil ? 0 : 1)
    }
    RunLoop.main.run()
}
if let i = args.firstIndex(of: "--snapshot-welcome"), args.count > i + 1 {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    MainActor.assumeIsolated {
        let model = AppModel()
        let host = NSHostingView(rootView: WelcomeView(model: model) {})
        host.frame = NSRect(x: 0, y: 0, width: 460, height: 400)
        let win = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        win.contentView = host
        win.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        win.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1]))
            }
            exit(0)
        }
    }
    app.run()
}
if let i = args.firstIndex(of: "--snapshot-hud"), args.count > i + 1 {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    MainActor.assumeIsolated {
        let model = AppModel()
        model.debugCatchUp(total: 7.3, elapsed: 2.6)
        let host = NSHostingView(rootView: CountdownView(model: model).padding(30).background(Color(white: 0.35)))
        host.frame = NSRect(x: 0, y: 0, width: 250, height: 250)
        let win = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        win.contentView = host
        win.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        win.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1]))
            }
            exit(0)
        }
    }
    app.run()
}
// Checks the menu window follows its content: starts too tall (the old bug), then unfolds and folds Settings.
if let i = args.firstIndex(of: "--menu-fit-check"), args.count > i + 1 {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    MainActor.assumeIsolated {
        let model = AppModel()
        let defaults = UserDefaults.standard
        let saved = defaults.bool(forKey: "showSettings")
        defaults.set(false, forKey: "showSettings")
        let host = NSHostingView(rootView: MenuView().environmentObject(model))
        let win = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 320, height: 900), styleMask: .borderless, backing: .buffered, defer: false)
        win.contentView = host
        win.orderFrontRegardless()
        var log: [String] = []
        let h = { win.contentRect(forFrameRect: win.frame).height }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { // lets the models finish loading first
            log.append("closed \(Int(h()))")
            defaults.set(true, forKey: "showSettings")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                log.append("open \(Int(h()))")
                defaults.set(false, forKey: "showSettings")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    log.append("closed again \(Int(h()))")
                    if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                        host.cacheDisplay(in: host.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1] + ".png"))
                    }
                    defaults.set(saved, forKey: "showSettings")
                    try? log.joined(separator: "\n").write(toFile: args[i + 1], atomically: true, encoding: .utf8)
                    exit(0)
                }
            }
        }
    }
    app.run()
}
if let i = args.firstIndex(of: "--permission-check"), args.count > i + 1 {
    try? "\(AudioPermission.systemAudio)".write(toFile: args[i + 1], atomically: true, encoding: .utf8)
    exit(0)
}
if args.contains("--hotkey-check") {
    let key = HotKey {}
    print("Option-Shift-V: handler \(key.status.handler), registration \(key.status.key) (0 = ok)")
    exit(key.status.handler == 0 && key.status.key == 0 ? 0 : 1)
}
if args.contains("--list") {
    for s in AudioProcesses.list() { print("\(s.isPlaying ? "♪" : " ") \(s.name) [\(s.id)] pids \(s.pids)") }
    exit(0)
}
if let i = args.firstIndex(of: "--sync-run"), args.count >= i + 4 {
    // Diagnostics: run the app model exactly like a user would (sync on), log once per second.
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    MainActor.assumeIsolated {
        let model = AppModel()
        let seconds = Double(args[i + 2]) ?? 30
        let logURL = URL(fileURLWithPath: args[i + 3])
        var lines: [String] = []
        var t0: Date?
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard model.ready else { return }
                if t0 == nil {
                    model.mode = Mode(rawValue: args[i + 1]) ?? .live
                    model.syncVideo = true
                    model.enabled = true
                    t0 = Date()
                }
                let s = model.stats
                let dev = (try? AudioProcesses.defaultOutputDevice()).flatMap { AudioProcesses.name(of: $0) } ?? "?"
                lines.append(String(format: "t=%4.1f perm=%@ silent=%.0f mode=%@ preparing=%@ catchup=%@ out=%@ default=%@ starts=%d reported=%.0f total=%.0f underruns=%d in=%.3f out=%.3f rtf=%.2f err=%@",
                                    Date().timeIntervalSince(t0!), "\(model.audioPermission)", model.silentFor, model.mode.title, model.preparing?.title ?? "-", model.catchUpSeconds.map(String.init) ?? "-", s.outputDevice, dev, model.starts, model.reportedLatencyMs, s.totalLatencyMs,
                                    s.underruns, s.inputPeak, s.outputPeak, s.realTimeFactor, model.error ?? "-"))
                try? lines.joined(separator: "\n").write(to: logURL, atomically: true, encoding: .utf8)
                // VOCALIZER_TEST_WAKE=<s>: post the "Mac woke up" notification once, at that time.
                if let w = ProcessInfo.processInfo.environment["VOCALIZER_TEST_WAKE"].flatMap(Double.init),
                   Date().timeIntervalSince(t0!) >= w, !lines.contains(where: { $0.hasPrefix("simulated wake") }) {
                    lines.append("simulated wake")
                    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: NSWorkspace.shared)
                }
                // VOCALIZER_TEST_SWITCH=<s>:<mode>: switch mode once at that time (like clicking it in the menu).
                if let spec = ProcessInfo.processInfo.environment["VOCALIZER_TEST_SWITCH"]?.split(separator: ":"), spec.count == 2,
                   let at = Double(spec[0]), Date().timeIntervalSince(t0!) >= at,
                   let m = Mode(rawValue: String(spec[1])), model.mode != m, !lines.contains(where: { $0.hasPrefix("switched") }) {
                    lines.append("switched to \(m.rawValue)")
                    model.mode = m
                }
                if Date().timeIntervalSince(t0!) > seconds {
                    model.enabled = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
                }
            }
        }
    }
    app.run()
}
if let i = args.firstIndex(of: "--snapshot"), args.count >= i + 4 {
    // Renders the real menu view to a PNG after running the engine on a source for a few seconds.
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    MainActor.assumeIsolated {
        let model = AppModel()
        model.mode = Mode(rawValue: args[i + 3]) ?? .live
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { t in
            MainActor.assumeIsolated {
                guard model.ready else { return }
                if !model.enabled {
                    model.sourceID = args[i + 2]
                    model.enabled = args[i + 2] != "off"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        // Off-screen window so AppKit-backed controls (switch, segmented) render too.
                        let host = NSHostingView(rootView: MenuView().environmentObject(model))
                        host.frame = NSRect(origin: .zero, size: host.fittingSize)
                        let win = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
                        win.contentView = host
                        win.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
                        win.orderFrontRegardless()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            host.layoutSubtreeIfNeeded()
                            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                                host.cacheDisplay(in: host.bounds, to: rep)
                                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1]))
                            }
                            model.enabled = false
                            exit(0)
                        }
                    }
                    t.invalidate()
                }
            }
        }
    }
    app.run()
}
VocalizerApp.main()
