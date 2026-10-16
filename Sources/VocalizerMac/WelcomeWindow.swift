// First-launch window: where the app lives, the two permissions, and the shortcut.
import AppKit
import SwiftUI

@MainActor
enum WelcomeWindow {
    private static var window: NSWindow?

    static func showIfFirstLaunch(model: AppModel) {
        guard !AppModel.testing, !UserDefaults.standard.bool(forKey: "welcomed") else { return }
        show(model: model)
    }

    static func show(model: AppModel) {
        let view = WelcomeView(model: model) {
            UserDefaults.standard.set(true, forKey: "welcomed")
            window?.close(); window = nil
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 400), styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "Welcome to Vocalizer"
        w.contentView = NSHostingView(rootView: view)
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

struct WelcomeView: View {
    @ObservedObject var model: AppModel
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Vocalizer").font(.title2.bold())
                    Text("Removes the music from anything your Mac plays. Keeps the voices.").foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            step("1", "Find it in the menu bar", "Click the microphone icon at the top right of your screen and flip the switch.")
            step("2", "Allow System Audio Recording", "The first time, macOS asks. Click Allow. Audio never leaves your Mac.")
            if model.driverInstalled {
                step("3", "Video stays in sync", "The Vocalizer audio device is installed, so videos wait for the voice.")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    step("3", "Keep video in sync (recommended)", "Installs a small audio device so videos wait for the voice. Asks for your password once.")
                    Button("Install the audio device…") { model.installDriver() }.padding(.leading, 34)
                }
            }
            step("4", "Shortcut ⌥⇧V", "Press Option-Shift-V anywhere to switch Vocalizer on or off.")
            Spacer()
            HStack {
                Toggle("Open at login", isOn: $model.openAtLogin)
                Spacer()
                Button("Got it", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 460, height: 400)
    }

    private func step(_ n: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(n).font(.caption.bold()).frame(width: 22, height: 22).background(Circle().fill(Color.accentColor.opacity(0.18)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
