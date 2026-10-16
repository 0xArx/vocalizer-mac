// Global keyboard shortcut (Carbon hot key: works without the Accessibility permission).
import Carbon
import Foundation

final class HotKey {
    private var ref: EventHotKeyRef?
    private static var action: (() -> Void)?
    /// OSStatus of installing the handler and registering the key (0 = ok); `--hotkey-check` prints it.
    private(set) var status: (handler: OSStatus, key: OSStatus) = (-1, -1)

    /// Default: Option-Shift-V, the same as the Vocalizer Chrome extension.
    init(keyCode: UInt32 = UInt32(kVK_ANSI_V), modifiers: UInt32 = UInt32(optionKey | shiftKey), action: @escaping () -> Void) {
        HotKey.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.action?() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x564F_434C), id: 1) // 'VOCL'
        let registered = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
        status = (installed, registered)
    }

    deinit { if let ref { UnregisterEventHotKey(ref) } }
}
