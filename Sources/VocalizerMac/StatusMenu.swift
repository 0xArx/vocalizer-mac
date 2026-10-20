// Right-click (or Control-click) on the Vocalizer icon in the menu bar: a small native menu with the
// version, Check for Updates, Licenses, Uninstall and Quit. A left click still opens the normal Vocalizer panel.
// SwiftUI's MenuBarExtra has no secondary-click menu, so we catch the click on our own status item window.

import AppKit

@MainActor
final class StatusMenu: NSObject {
    private var monitor: Any?
    private let uninstall: () -> Void
    private let checkForUpdates: () -> Void

    init(uninstall: @escaping () -> Void, checkForUpdates: @escaping () -> Void) {
        self.uninstall = uninstall
        self.checkForUpdates = checkForUpdates
        super.init()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
            guard let self, let window = event.window,
                  NSStringFromClass(type(of: window)).contains("StatusBarWindow") else { return event }
            let secondary = event.type == .rightMouseDown || event.modifierFlags.contains(.control)
            guard secondary else { return event }
            self.show(in: window)
            return nil
        }
    }

    private func show(in window: NSWindow) {
        let menu = NSMenu()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let title = NSMenuItem(title: L("Vocalizer %@", version), action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())
        let check = NSMenuItem(title: L("Check for Updates…"), action: #selector(checkClicked), keyEquivalent: "")
        check.target = self
        menu.addItem(check)
        let licenses = NSMenuItem(title: L("Licenses…"), action: #selector(licensesClicked), keyEquivalent: "")
        licenses.target = self
        menu.addItem(licenses)
        let remove = NSMenuItem(title: L("Uninstall Vocalizer…"), action: #selector(uninstallClicked), keyEquivalent: "")
        remove.target = self
        menu.addItem(remove)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: L("Quit Vocalizer"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        guard let view = window.contentView else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.minY - 4), in: view)
    }

    @objc private func uninstallClicked() { uninstall() }
    @objc private func checkClicked() { checkForUpdates() }
    /// The open-source parts Vocalizer is built on and their licenses (bundled text file).
    @objc private func licensesClicked() {
        if let url = Bundle.main.url(forResource: "THIRD-PARTY-NOTICES", withExtension: "txt") { NSWorkspace.shared.open(url) }
    }
}
