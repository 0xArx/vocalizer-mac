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
                lines.append(String(format: "t=%4.0f out=%@ default=%@ starts=%d reported=%.0f total=%.0f underruns=%d in=%.3f out=%.3f rtf=%.2f err=%@",
                                    Date().timeIntervalSince(t0!), s.outputDevice, dev, model.starts, model.reportedLatencyMs, s.totalLatencyMs,
                                    s.underruns, s.inputPeak, s.outputPeak, s.realTimeFactor, model.error ?? "-"))
                try? lines.joined(separator: "\n").write(to: logURL, atomically: true, encoding: .utf8)
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
