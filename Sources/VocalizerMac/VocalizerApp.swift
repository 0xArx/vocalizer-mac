import SwiftUI
import VocalizerCore

struct VocalizerApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuView().environmentObject(model)
        } label: {
            // An hourglass while a video waits for the voice (Best's ~7 s) or Best is loading.
            if model.preparing != nil || model.catchUpSeconds != nil {
                Image(systemName: Int(Date().timeIntervalSince1970 * 2) % 2 == 0 ? "hourglass.tophalf.filled" : "hourglass.bottomhalf.filled")
            } else {
                Image(systemName: model.enabled ? "music.mic.circle.fill" : "music.mic")
            }
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("showSettings") private var showSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(16)
            waitBar
            notices
            Divider().padding(.horizontal, 16)
            modePicker.padding(16)
            Divider().padding(.horizontal, 16)
            outputRow.padding(.horizontal, 16).padding(.vertical, 10)
            Divider().padding(.horizontal, 16)
            settings.padding(.horizontal, 16).padding(.vertical, 10)
            footer.padding(.horizontal, 16).padding(.bottom, 12).padding(.top, 2)
        }
        .frame(width: 320)
        .onAppear { model.refreshSources(); model.refreshOutputs() }
    }

    // MARK: header: icon, name, plain-language status, the one big switch

    private var on: Bool { model.enabled && model.stats.running }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(on ? AnyShapeStyle(LinearGradient(colors: [Color(red: 0.42, green: 0.27, blue: 0.95), Color(red: 0.93, green: 0.30, blue: 0.55)],
                                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                             : AnyShapeStyle(Color.secondary.opacity(0.18)))
                Image(systemName: "music.mic").font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(on ? .white : .secondary)
            }
            .frame(width: 38, height: 38)
            .animation(.easeInOut(duration: 0.25), value: on)
            VStack(alignment: .leading, spacing: 2) {
                Text("Vocalizer").font(.system(size: 15, weight: .semibold))
                Text(statusLine).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: $model.enabled).toggleStyle(.switch).labelsHidden().disabled(!model.ready)
        }
    }

    /// A thin bar while Best loads (sliding) or while videos wait for the voice (filling).
    @ViewBuilder private var waitBar: some View {
        if model.preparing != nil {
            ProgressView().progressViewStyle(.linear).controlSize(.small)
                .padding(.horizontal, 16).padding(.top, -6).padding(.bottom, 12)
        } else if on, let p = model.catchUpProgress {
            ProgressView(value: p).progressViewStyle(.linear).controlSize(.small).tint(.accentColor)
                .padding(.horizontal, 16).padding(.top, -6).padding(.bottom, 12)
                .animation(.linear(duration: 0.5), value: p)
        }
    }

    private var statusLine: String {
        if !model.ready { return "Getting ready…" }
        if let p = model.preparing { return "Preparing \(p.title)…" }
        if on, let n = model.catchUpSeconds { return "Video starts in \(n) s" }
        if model.enabled && model.mode.separation == nil { return "Download needed for Best" }
        if model.enabled && !model.stats.running { return "Starting…" }
        if on { return "Removing the music" }
        return "Off. Sound plays normally"
    }

    // MARK: at most one gentle notice at a time

    @ViewBuilder private var notices: some View {
        if let e = model.error {
            notice("exclamationmark.triangle.fill", .orange, e, nil, nil)
        } else if on && model.silentFor > 4 && model.sources.contains(where: \.isPlaying) {
            // Something is playing but nothing reaches us: almost always the recording permission.
            notice("hand.raised.fill", .orange, "No sound is coming in. If something is playing, allow Vocalizer in System Settings › Privacy & Security › Screen & System Audio Recording.", nil, nil)
        } else if model.mode == .supreme && !model.supremeReady {
            if let p = model.supremeProgress {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Downloading Best quality…").font(.system(size: 12))
                    ProgressView(value: p).controlSize(.small)
                }
                .padding(10).background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
                .padding(.horizontal, 16).padding(.bottom, 12)
            } else {
                notice("arrow.down.circle.fill", .accentColor, "Best quality needs a one-time 400 MB download.", "Download") { model.downloadSupreme() }
            }
        } else if model.syncVideo && !model.driverInstalled {
            notice("film", .accentColor, "Install the Vocalizer audio device so videos stay in sync.", "Install") { model.installDriver() }
        } else if model.updater.updateAvailable, let v = model.updater.latest {
            notice("sparkles", .accentColor, "Vocalizer \(v) is available.", model.updater.updating ? "Updating…" : "Update") { model.updater.update() }
        }
    }

    private func notice(_ icon: String, _ tint: Color, _ text: String, _ button: String?, _ action: (() -> Void)?) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint).font(.system(size: 13))
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let button, let action {
                Button(button, action: action).controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(0.10)))
        .padding(.horizontal, 16).padding(.bottom, 12)
    }

    // MARK: mode tiles

    private var modePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(model.availableModes) { m in
                    Button { model.mode = m } label: {
                        VStack(spacing: 5) {
                            if model.preparing == m {
                                ProgressView().controlSize(.small).frame(height: 18)
                            } else {
                                Image(systemName: m.symbol).font(.system(size: 15, weight: .medium)).frame(height: 18)
                            }
                            Text(m.title).font(.system(size: 11.5, weight: .medium))
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 9)
                        .foregroundStyle(model.mode == m ? Color.accentColor : .primary.opacity(0.75))
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(model.mode == m ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.07))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(model.mode == m ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Text(model.mode.hint(delaySeconds: model.mode.expectedDelayMs(sync: model.syncActive) / 1000))
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: where it plays

    private var outputRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.wave.2.fill").foregroundStyle(.secondary).frame(width: 18)
            Text("Plays on").font(.system(size: 12.5)).foregroundStyle(.secondary)
            Spacer()
            Picker("", selection: Binding(get: { model.currentOutputUID ?? "" }, set: { model.choose(output: $0) })) {
                ForEach(model.outputs) { o in Text(o.name).tag(o.id) }
            }
            .labelsHidden().pickerStyle(.menu).fixedSize()
        }
    }

    // MARK: settings, folded away

    private var settings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(.easeInOut(duration: 0.2)) { showSettings.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape").foregroundStyle(.secondary).frame(width: 18)
                    Text("Settings").font(.system(size: 12.5)).foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(showSettings ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showSettings {
                VStack(alignment: .leading, spacing: 12) {
                    settingToggle("Keep video in sync", "Videos wait for the voice, so lips always match.", $model.syncVideo)
                    settingToggle("Open at login", "Start Vocalizer when you log in.", $model.openAtLogin)
                    if !model.syncActive {
                        HStack {
                            Text("Only remove music from").font(.system(size: 12.5))
                            Spacer()
                            Picker("", selection: $model.sourceID) {
                                Text("All apps").tag(AudioSource.all.id)
                                Divider()
                                ForEach(model.sources) { s in Text(s.isPlaying ? "\(s.name) ♪" : s.name).tag(s.id) }
                            }
                            .labelsHidden().pickerStyle(.menu).fixedSize()
                        }
                    }
                    StatusView()
                }
                .padding(.leading, 26)
                .transition(.opacity)
            }
        }
    }

    private func settingToggle(_ title: String, _ detail: String, _ value: Binding<Bool>) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: value).toggleStyle(.switch).controlSize(.mini).labelsHidden()
        }
    }

    private var footer: some View {
        HStack {
            Text("⌥⇧V turns it on or off").font(.system(size: 11)).foregroundStyle(.tertiary)
            Spacer()
            // Quitting keeps "on" remembered, so it resumes next launch.
            Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}

/// Technical details, shown inside Settings while running.
struct StatusView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let s = model.stats
        if s.running {
            VStack(alignment: .leading, spacing: 3) {
                Text("Details").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Text(String(format: "Delay %.2f s · %@ · %@", s.totalLatencyMs / 1000,
                            s.realTimeFactor > 0 ? String(format: "%.0f× faster than real time", 1 / s.realTimeFactor) : "starting",
                            s.underruns == 0 ? "no glitches" : "\(s.underruns) glitches"))
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                Text("Version \(model.updater.current)").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        } else {
            Text("Version \(model.updater.current)").font(.system(size: 11)).foregroundStyle(.tertiary)
        }
    }
}
