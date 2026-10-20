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
                Image(nsImage: MenuIcon.image(on: model.enabled))
            }
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("showSettings") private var showSettings = false
    @AppStorage("screenCountdown") private var screenCountdown = true
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(16)
            waitBar
            notices
            if !model.fastOnly {
                Divider().padding(.horizontal, 16)
                modePicker.padding(16)
            }
            Divider().padding(.horizontal, 16)
            outputRow.padding(.horizontal, 16).padding(.vertical, 10)
            if model.swearFilterSupported {
                swearRow.padding(.horizontal, 16).padding(.bottom, 10)
            }
            Divider().padding(.horizontal, 16)
            settings.padding(.horizontal, 16).padding(.vertical, 10)
            footer.padding(.horizontal, 16).padding(.bottom, 12).padding(.top, 2)
        }
        .frame(width: 320)
        .environment(\.layoutDirection, appLayoutDirection)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { g in Color.clear.preference(key: MenuHeightKey.self, value: g.size.height) })
        .onPreferenceChange(MenuHeightKey.self) { contentHeight = $0 }
        .background(MenuWindowFitter(height: contentHeight))
        .onAppear { model.refreshSources(); model.refreshOutputs() }
    }

    // MARK: header: icon, name, plain-language status, the one big switch

    private var on: Bool { model.enabled && model.stats.running }

    private var header: some View {
        HStack(spacing: 12) {
            // The app icon: full colour when on, faded grey when off.
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().interpolation(.high)
                .saturation(on ? 1 : 0).opacity(on ? 1 : 0.55)
                .scaleEffect(1.12) // the icon art has transparent margins
            .frame(width: 38, height: 38)
            .animation(.easeInOut(duration: 0.25), value: on)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "Vocalizer").font(.system(size: 15, weight: .semibold))
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
        if !model.ready { return L("Getting ready…") }
        if let p = model.preparing { return L("Preparing %@…", p.title) }
        if on, let n = model.catchUpSeconds { return L("Video starts in %@ s", "\(n)") }
        if model.enabled && model.mode.separation == nil { return L("Download needed for Best") }
        if model.enabled && !model.stats.running { return L("Starting…") }
        if on { return L("Removing the music") }
        return L("Off. Sound plays normally")
    }

    // MARK: at most one gentle notice at a time

    @ViewBuilder private var notices: some View {
        if let e = model.error {
            notice("exclamationmark.triangle.fill", .orange, e, nil, nil)
        } else if model.enabled && model.audioPermission == .denied {
            // macOS says we may not hear other apps: say so plainly and go straight to the setting.
            notice("hand.raised.fill", .orange, L("Vocalizer isn't allowed to hear other apps yet. Turn on Vocalizer under System Audio Recording."), L("Open Settings")) {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
            }
        } else if on && model.audioPermission == .unknown && model.silentFor > 8 && model.sources.contains(where: \.isPlaying) {
            // Permission not decided yet (macOS asks on first use) and nothing arrives: point at the prompt.
            notice("hand.raised.fill", .orange, L("No sound yet. If macOS asked about System Audio Recording, click Allow."), nil, nil)
        } else if model.mode == .supreme && !model.supremeReady {
            if let p = model.supremeProgress {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Downloading Best quality…")).font(.system(size: 12))
                    ProgressView(value: p).controlSize(.small)
                }
                .padding(10).background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
                .padding(.horizontal, 16).padding(.bottom, 12)
            } else {
                notice("arrow.down.circle.fill", .accentColor, L("Best quality needs a one-time 400 MB download."), L("Download")) { model.downloadSupreme() }
            }
        } else if model.syncVideo && !model.driverInstalled {
            notice("film", .accentColor, L("Install the Vocalizer audio device so videos stay in sync."), L("Install")) { model.installDriver() }
        } else if model.driverInstalled && model.driverOutdated {
            notice("film", .accentColor, L("A newer audio device came with this update."), L("Update")) { model.installDriver() }
        } else if let v = model.updater.ready {
            notice("sparkles", .accentColor, L("Vocalizer %@ is ready. It installs when nothing is playing.", v), L("Install now")) { model.updater.installReadyUpdate() }
        } else if let v = model.updater.available {
            notice("sparkles", .accentColor, model.updater.installing ? L("Updating to Vocalizer %@…", v) : L("Vocalizer %@ is available.", v),
                   model.updater.installing ? nil : L("Update")) { model.updater.installAvailable() }
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
            Text(L("Plays on")).font(.system(size: 12.5)).foregroundStyle(.secondary)
            Spacer()
            Picker("", selection: Binding(get: { model.currentOutputUID ?? "" }, set: { model.choose(output: $0) })) {
                ForEach(model.outputs) { o in Text(o.name).tag(o.id) }
            }
            .labelsHidden().pickerStyle(.menu).fixedSize()
        }
    }

    // MARK: swear-word filter

    private var swearRow: some View {
        let s = model.stats
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: model.muteSwearWords ? "speaker.slash.fill" : "speaker.slash")
                    .foregroundStyle(model.muteSwearWords ? Color.accentColor : .secondary).frame(width: 18)
                Text(L("Mute swear words")).font(.system(size: 12.5))
                Spacer()
                if model.muteSwearWords && on {
                    Group {
                        if s.profanityPreparing {
                            HStack(spacing: 4) { ProgressView().controlSize(.mini); Text(L("Getting ready")) }
                        } else if s.profanityError != nil {
                            Text(L("Unavailable"))
                        } else if s.profanityFilter {
                            Text(s.wordsCaught == 0 ? L("Listening") : L("%@ muted", "\(s.wordsCaught)"))
                        }
                    }
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Toggle("", isOn: $model.muteSwearWords).toggleStyle(.switch).controlSize(.mini).labelsHidden()
            }
            if model.muteSwearWords {
                Text(swearHint).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.leading, 26)
            }
        }
    }

    private var swearHint: String {
        if let e = model.stats.profanityError, model.muteSwearWords { return L("Speech recognition isn't available: %@", "\(e)") }
        switch model.mode {
        case .live, .ultra, .balanced:
            return model.fastOnly
                ? L("Fast is too quick: words play before they're recognized. Turn off Fast only and use Best or Clean.")
                : L("This mode is too quick: words play before they're recognized. Use Best or Clean.")
        case .quality:
            return L("Catches most swear words, sometimes with a bit of the next word. Best is more precise.")
        case .supreme:
            return L("Catches nearly every swear word, precisely. Recognized on this Mac.")
        }
    }

    // MARK: settings, folded away

    private var settings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(.easeInOut(duration: 0.2)) { showSettings.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape").foregroundStyle(.secondary).frame(width: 18)
                    Text(L("Settings")).font(.system(size: 12.5)).foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(showSettings ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showSettings {
                VStack(alignment: .leading, spacing: 12) {
                    settingToggle(L("Fast only"), L("Hide the other modes and always use Fast."), $model.fastOnly)
                    settingToggle(L("Keep video in sync"), L("Videos wait for the voice, so lips always match."), $model.syncVideo)
                    settingToggle(L("Open at login"), L("Start Vocalizer when you log in."), $model.openAtLogin)
                    settingToggle(L("Install updates automatically"), L("Off: Vocalizer tells you about new versions and asks first."),
                                  Binding(get: { model.updater.automaticallyInstalls }, set: { model.updater.automaticallyInstalls = $0 }))
                    if !model.fastOnly {
                        settingToggle(L("Show countdown on screen"), L("While a video waits for the voice (Best, Clean)."), $screenCountdown)
                    }
                    if !model.syncActive {
                        HStack {
                            Text(L("Only remove music from")).font(.system(size: 12.5))
                            Spacer()
                            Picker("", selection: $model.sourceID) {
                                Text(L("All apps")).tag(AudioSource.all.id)
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
            Text(L("⌥⇧V turns it on or off")).font(.system(size: 11)).foregroundStyle(.tertiary)
            Spacer()
            // Quitting keeps "on" remembered, so it resumes next launch.
            Button(L("Quit")) { NSApp.terminate(nil) }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
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
                Text(L("Details")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Text(L("Delay %@ s · %@ · %@", String(format: "%.2f", s.totalLatencyMs / 1000),
                            s.realTimeFactor > 0 ? L("%@× faster than real time", String(format: "%.0f", 1 / s.realTimeFactor)) : L("starting"),
                            s.underruns == 0 ? L("no glitches") : L("%@ glitches", "\(s.underruns)")))
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                Text(L("Version %@", model.updater.current)).font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        } else {
            Text(L("Version %@", model.updater.current)).font(.system(size: 11)).foregroundStyle(.tertiary)
        }
    }
}

private struct MenuHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// MenuBarExtra's window grows with its content but doesn't always shrink back (folding Settings away left an
/// empty panel). This keeps the window exactly as tall as the content, anchored at the top under the menu bar.
private struct MenuWindowFitter: NSViewRepresentable {
    let height: CGFloat
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        let height = height
        DispatchQueue.main.async {
            guard height > 0, let window = view.window else { return }
            let content = window.contentRect(forFrameRect: window.frame)
            guard abs(content.height - height) > 0.5 else { return }
            let fitted = NSRect(x: content.minX, y: content.maxY - height, width: content.width, height: height)
            window.setFrame(window.frameRect(forContentRect: fitted), display: true)
        }
    }
}
