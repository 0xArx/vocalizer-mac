// Right-click (or Control-click) on the Vocalizer icon in the menu bar: a small native menu with the
// version, Uninstall and Quit. A left click still opens the normal Vocalizer panel.
// SwiftUI's MenuBarExtra has no secondary-click menu, so we catch the click on our own status item window.

import AppKit

@MainActor
final class StatusMenu: NSObject {
    private var monitor: Any?
    private let uninstall: () -> Void

    init(uninstall: @escaping () -> Void) {
        self.uninstall = uninstall
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
        let title = NSMenuItem(title: "Vocalizer \(version)", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())
        let remove = NSMenuItem(title: "Uninstall Vocalizer…", action: #selector(uninstallClicked), keyEquivalent: "")
        remove.target = self
        menu.addItem(remove)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Vocalizer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        guard let view = window.contentView else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.minY - 4), in: view)
    }

    @objc private func uninstallClicked() { uninstall() }
}
