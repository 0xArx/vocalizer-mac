// Updates with Sparkle. Vocalizer checks the appcast on the website every 4 hours and, by default, only tells
// you: a quiet "update available" note in its menu, never a window popping up, and nothing installs until you
// click. Every update's EdDSA signature (SUPublicEDKey) and Developer ID are checked before it installs.
// Optional (Settings › Install updates automatically): download in the background and install when you're not
// listening (Vocalizer off, or nothing playing for a minute), then reopen as it was.
import AppKit
import Sparkle

@MainActor
final class Updater: NSObject, ObservableObject {
    let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    /// Set by AppModel: true when installing now would not interrupt anything.
    var isIdle: () -> Bool = { true }
    /// The version waiting to be installed (downloaded and verified), if any (automatic mode).
    @Published private(set) var ready: String?
    /// A newer version that was found and is waiting for you to choose to install it (ask-first mode).
    @Published private(set) var available: String?

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

    /// Shows Sparkle's window (what's new, Install / Later). Also used by the menu's "Update…" button.
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
                NSLog("Vocalizer update: idle, installing now")
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
    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        NSLog("Vocalizer update: found %@", item.displayVersionString)
    }
    nonisolated func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        NSLog("Vocalizer update: downloaded %@", item.displayVersionString)
    }
    nonisolated func updater(_ updater: SPUUpdater, didExtractUpdate item: SUAppcastItem) {
        NSLog("Vocalizer update: verified and unpacked %@", item.displayVersionString)
    }
    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        NSLog("Vocalizer update: stopped: %@", error.localizedDescription)
    }
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        let version = item.displayVersionString
        NSLog("Vocalizer update: %@ ready, installing when idle", version)
        MainActor.assumeIsolated {
            self.ready = version
            self.installNow = immediateInstallHandler
            self.waitForIdle()
        }
        return true
    }
}

extension Updater: SPUStandardUserDriverDelegate {
    // Found by a background check: don't pop a window over what you're doing. Show a note in the menu instead,
    // and open Sparkle's window only when you click it.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        let version = update.displayVersionString
        MainActor.assumeIsolated {
            if !handleShowingUpdate && !state.userInitiated {
                NSLog("Vocalizer update: %@ available, waiting for you to choose", version)
                self.available = version
            }
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { self.available = nil }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { self.available = nil }
    }
}
