// Updates with Sparkle: checks the appcast on the website every 4 hours, downloads new versions in the
// background, and checks each one's EdDSA signature (SUPublicEDKey) and Developer ID before installing.
// Installs happen when you're not listening (Vocalizer off, or nothing playing for a minute), then the
// app reopens as it was. Settings has the "Install updates automatically" switch.
import AppKit
import Sparkle

@MainActor
final class Updater: NSObject, ObservableObject {
    let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    /// Set by AppModel: true when installing now would not interrupt anything.
    var isIdle: () -> Bool = { true }
    /// The version waiting to be installed (downloaded and verified), if any.
    @Published private(set) var ready: String?

    private var controller: SPUStandardUpdaterController?
    private var installNow: (() -> Void)?
    private var idleTimer: Timer?

    override init() {
        super.init()
        guard !AppModel.testing else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        // Test hook: check at once (with VOCALIZER_FEED_URL pointing at a local appcast).
        if ProcessInfo.processInfo.environment["VOCALIZER_UPDATE_NOW"] != nil {
            controller?.updater.checkForUpdatesInBackground()
        }
    }

    var automaticallyInstalls: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set { controller?.updater.automaticallyDownloadsUpdates = newValue; objectWillChange.send() }
    }

    var canCheck: Bool { controller?.updater.canCheckForUpdates ?? false }

    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }

    /// Installs the downloaded update right away (the app quits and reopens).
    func installReadyUpdate() { installNow?() }

    private func waitForIdle() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isIdle(), let install = self.installNow else { return }
                self.idleTimer?.invalidate()
                install()
            }
        }
    }
}

extension Updater: SPUUpdaterDelegate {
    /// Test hook: another appcast (e.g. a local one) instead of SUFeedURL.
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        ProcessInfo.processInfo.environment["VOCALIZER_FEED_URL"]
    }

    /// A verified update is downloaded. Install it as soon as nothing is playing, instead of waiting for a
    /// quit that a menu bar app may not see for weeks.
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        let version = item.displayVersionString
        MainActor.assumeIsolated {
            self.ready = version
            self.installNow = immediateInstallHandler
            self.waitForIdle()
        }
        return true
    }
}

extension Updater: SPUStandardUserDriverDelegate {
    // A menu bar app has no Dock icon to badge: let Sparkle remind gently instead of stealing focus.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }
}
