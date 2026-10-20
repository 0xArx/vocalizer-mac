// Updates. Sparkle finds them: it reads the appcast on the website every 4 hours (signed with EdDSA). By
// default Vocalizer only tells you, with a quiet note in its menu and no window, and installs when you click
// Update. With Settings › Install updates automatically, new versions install by themselves when nothing is playing.
//
// Installing is done by SelfInstaller (swap the whole app, no password) because macOS App Management stops
// Sparkle from installing a notarized app without an administrator. Sparkle's own installer is still used
// when it can work silently (e.g. un-notarized test builds), and its window is the fallback if ours fails.
import AppKit
import Sparkle

@MainActor
final class Updater: NSObject, ObservableObject {
    let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    /// Set by AppModel: true when installing now would not interrupt anything.
    var isIdle: () -> Bool = { true }
    /// A verified update waiting for a quiet moment (automatic mode).
    @Published private(set) var ready: String?
    /// A newer version waiting for you to choose to install it (ask-first mode).
    @Published private(set) var available: String?
    /// Downloading and checking an update right now.
    @Published private(set) var installing = false

    private var controller: SPUStandardUpdaterController?
    private var installNow: (() -> Void)?
    private var idleTimer: Timer?
    private var foundItem: SUAppcastItem?
    private var manualCheck = false

    override init() {
        super.init()
        guard !AppModel.testing else { return }
        SelfInstaller.cleanUpLeftovers()
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

    /// "Check for Updates…": checks now and says what it found.
    func checkForUpdates() {
        if available != nil { promptToInstall(); return }
        manualCheck = true
        controller?.updater.checkForUpdatesInBackground()
    }

    /// The menu's "Update" button: install the available version now.
    func installAvailable() {
        guard let item = foundItem, !installing else { return }
        installing = true
        Task {
            do {
                let prepared = try await SelfInstaller.prepare(item)
                try SelfInstaller.install(prepared)
            } catch {
                NSLog("Vocalizer update: own install failed (%@), using Sparkle", error.localizedDescription)
                installing = false
                NSApp.activate(ignoringOtherApps: true)
                controller?.checkForUpdates(nil)
            }
        }
    }

    /// Installs the downloaded update right away (the app quits and reopens).
    func installReadyUpdate() { installNow?() }

    /// Automatic mode: download and verify in the background, then install at the next quiet moment.
    private func prepareInBackground(_ item: SUAppcastItem) {
        guard !installing, ready == nil else { return }
        installing = true
        Task {
            do {
                let prepared = try await SelfInstaller.prepare(item)
                installing = false
                available = nil
                ready = prepared.version
                installNow = {
                    do { try SelfInstaller.install(prepared) }
                    catch { NSLog("Vocalizer update: swap failed: %@", error.localizedDescription) }
                }
                NSLog("Vocalizer update: %@ ready, installing when idle", prepared.version)
                waitForIdle()
            } catch {
                installing = false
                NSLog("Vocalizer update: background install failed (%@); it stays available in the menu", error.localizedDescription)
            }
        }
    }

    private func promptToInstall() {
        manualCheck = false
        guard let version = available else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Vocalizer \(version) is available"
        alert.informativeText = "You have \(current). Install it now? Vocalizer quits and reopens in a few seconds."
        alert.addButton(withTitle: "Install Now")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "What's New")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            installAvailable()
        case .alertThirdButtonReturn:
            if let url = URL(string: "https://github.com/0xArx/vocalizer-mac/releases/tag/v\(version)") { NSWorkspace.shared.open(url) }
        default:
            break
        }
    }

    private func waitForIdle() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isIdle(), let install = self.installNow else { return }
                self.idleTimer?.invalidate()
                NSLog("Vocalizer update: idle, installing now")
                install()
            }
        }
    }

    /// A background check found an update and Sparkle left it to us.
    private func found(_ item: SUAppcastItem) {
        foundItem = item
        available = item.displayVersionString
        NSLog("Vocalizer update: %@ available", item.displayVersionString)
        if automaticallyInstalls { prepareInBackground(item) }
        else if ProcessInfo.processInfo.environment["VOCALIZER_TEST_CLICK_UPDATE"] != nil { installAvailable() } // test hook
        if manualCheck { promptToInstall() }
    }
}

extension Updater: SPUUpdaterDelegate {
    /// Test hook: another appcast (e.g. a local one) instead of SUFeedURL.
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        ProcessInfo.processInfo.environment["VOCALIZER_FEED_URL"]
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        NSLog("Vocalizer update: found %@", item.displayVersionString)
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        MainActor.assumeIsolated {
            guard self.manualCheck else { return }
            self.manualCheck = false
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Vocalizer is up to date"
            alert.informativeText = "You have the latest version, \(self.current)."
            alert.runModal()
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        NSLog("Vocalizer update: stopped: %@", error.localizedDescription)
    }

    /// Sparkle's own silent install worked (possible when the app isn't protected, e.g. test builds).
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
    // Found by a background check: never pop Sparkle's window over what you're doing.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        MainActor.assumeIsolated {
            if !handleShowingUpdate && !state.userInitiated { self.found(update) }
        }
    }
}
