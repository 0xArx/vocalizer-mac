// Two Finder ways to remove Vocalizer, since macOS doesn't let apps add their own right-click items:
//  - Services: right-click Vocalizer in Applications › Services › Uninstall Vocalizer (Info.plist NSServices).
//  - The Bin: drag Vocalizer to the Bin while it runs and it offers to remove its audio device, models and
//    settings too, so nothing is left behind.

import AppKit

@MainActor
final class Uninstaller: NSObject {
    private let uninstall: () -> Void
    private let movedToTrash: () -> Void
    private let bundleRef: NSURL?
    private var timer: Timer?
    private var asked = false

    init(uninstall: @escaping () -> Void, movedToTrash: @escaping () -> Void) {
        self.uninstall = uninstall
        self.movedToTrash = movedToTrash
        // A file reference keeps pointing at the app even after Finder moves it.
        bundleRef = (Bundle.main.bundleURL as NSURL).fileReferenceURL() as NSURL?
        super.init()
        NSApp.servicesProvider = self
        Uninstaller.enableFinderEntry()
        NSUpdateDynamicServices()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkTrash() }
        }
    }

    /// New services can start switched off for Finder's right-click menu. Turn ours on once (the same switch
    /// as System Settings › Keyboard › Keyboard Shortcuts › Services); if the user later turns it off, leave it.
    private static func enableFinderEntry() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let key = "\(id) - Uninstall Vocalizer - uninstallService"
        let domain = "pbs" as CFString
        var status = CFPreferencesCopyAppValue("NSServicesStatus" as CFString, domain) as? [String: Any] ?? [:]
        guard status[key] == nil else { return }
        status[key] = ["enabled_context_menu": true, "enabled_services_menu": true,
                       "presentation_modes": ["ContextMenu": true, "ServicesMenu": true]]
        CFPreferencesSetAppValue("NSServicesStatus" as CFString, status as CFDictionary, domain)
        CFPreferencesAppSynchronize(domain)
    }

    private func checkTrash() {
        guard !asked, let path = bundleRef?.filePathURL?.path else { return }
        if path.contains("/.Trash/") {
            asked = true
            timer?.invalidate()
            movedToTrash()
        }
    }

    /// Services entry point. The menu item shows for any app the user right-clicks, so only act on ours.
    @objc func uninstallService(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let mine = Bundle.main.bundleIdentifier
        let picked = urls.contains { Bundle(url: $0)?.bundleIdentifier == mine }
        guard picked || urls.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "That isn't Vocalizer"
            alert.informativeText = "Uninstall Vocalizer only removes Vocalizer. Right-click Vocalizer in your Applications folder to use it."
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }
        uninstall()
    }
}
