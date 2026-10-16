import SwiftUI
import VocalizerCore

struct VocalizerApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuView().environmentObject(model)
        } label: {
            Image(systemName: model.enabled ? "music.mic.circle.fill" : "music.mic")
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Vocalizer").font(.headline)
                    Text("Removes music, keeps voices")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: $model.enabled).toggleStyle(.switch).labelsHidden().disabled(!model.ready)
            }

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Keep video in sync", isOn: $model.syncVideo)
                if model.syncActive {
                    Text(model.reportedLatencyMs > 0
                         ? String(format: "All audio goes through the Vocalizer device. Videos are held back %.0f ms to match.", model.reportedLatencyMs)
                         : "All audio goes through the Vocalizer device, and videos are held back to match the delay.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else if model.syncVideo {
                    HStack {
                        Text("Needs the Vocalizer audio device.").font(.caption).foregroundStyle(.secondary)
                        Button("Install…") { model.installDriver() }.controlSize(.small)
                    }
                }
            }

            if !model.syncActive {
                Picker("Source", selection: $model.sourceID) {
                    Text("All audio").tag(AudioSource.all.id)
                    Divider()
                    ForEach(model.sources) { s in
                        Text(s.isPlaying ? "\(s.name) ♪" : s.name).tag(s.id)
                    }
                }
                .onAppear { model.refreshSources() }
            }

            Picker("Output", selection: Binding(get: { model.currentOutputUID ?? "" },
                                                set: { model.choose(output: $0) })) {
                ForEach(model.outputs) { o in Text(o.name).tag(o.id) }
            }
            .onAppear { model.refreshOutputs() }

            Text("Mode").font(.subheadline)
            Picker("Mode", selection: $model.mode) {
                ForEach(model.availableModes) { m in Text(m.title).tag(m) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(model.mode.hint + String(format: " · about %.1f s delay", model.mode.expectedDelayMs(sync: model.syncActive) / 1000))
                .font(.caption).foregroundStyle(.secondary)
            if model.mode == .supreme && !model.supremeReady {
                if let p = model.supremeProgress {
                    ProgressView(value: p) { Text("Downloading the Supreme model…").font(.caption) }
                } else {
                    HStack {
                        Text("Supreme needs a one-time model download (about 410 MB).").font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Download") { model.downloadSupreme() }.controlSize(.small)
                    }
                }
            } else if model.mode == .supreme && !model.syncActive {
                Text("Tip: turn on Keep video in sync, so videos wait for the voice.").font(.caption).foregroundStyle(.orange)
            }

            Divider()
            StatusView()

            HStack {
                Toggle("Open at login", isOn: $model.openAtLogin).controlSize(.small)
                Spacer()
                // Quitting keeps "on" remembered, so it resumes next launch.
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 370)
        .onAppear { model.refreshSources() }
    }
}

struct StatusView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let s = model.stats
        VStack(alignment: .leading, spacing: 4) {
            if let e = model.error {
                Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.caption)
            }
            if !model.ready {
                Label("Loading the model onto the Neural Engine…", systemImage: "hourglass").font(.caption)
            } else if s.running {
                row("Latency", String(format: "%.0f ms (%.0f pipeline + %.0f device)", s.totalLatencyMs, s.pipelineLatencyMs, s.deviceLatencyMs))
                row("Speed", s.realTimeFactor > 0
                    ? String(format: "%.0f× real time (RTF %.2f), %.0f ms per step", 1 / s.realTimeFactor, s.realTimeFactor, s.stepMs)
                    : "starting…")
                row("Output", "\(s.outputDevice) · \(Int(s.sampleRate)) Hz")
                row("Levels", String(format: "in %@  out %@", meter(s.inputPeak), meter(s.outputPeak)))
                if s.underruns > 0 { row("Glitches", "\(s.underruns)") }
                if model.silentFor > 4 {
                    Text("No audio is coming in. If the app is playing, allow Vocalizer in System Settings › Privacy & Security › Screen & System Audio Recording.")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Off. The source plays normally.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).font(.caption).foregroundStyle(.secondary).frame(width: 58, alignment: .leading)
            Text(v).font(.caption.monospacedDigit())
        }
    }

    private func meter(_ peak: Float) -> String {
        let db = 20 * log10(max(peak, 1e-6))
        return peak < 1e-4 ? "silent" : String(format: "%.0f dB", db)
    }
}
