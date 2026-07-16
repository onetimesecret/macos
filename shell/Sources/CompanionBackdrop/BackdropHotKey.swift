import Carbon.HIToolbox
import Foundation

/// The raise/rest hotkey (⌃⌥Space) as a Carbon `RegisterEventHotKey`
/// registration — the one system-wide key this form factor claims.
/// Carbon is the deliberate choice, as in the panel: it needs no
/// Accessibility permission and it consumes the keystroke.
///
/// ⌃⌥Space rather than ⌥Space for two reasons: the panel already holds
/// ⌥Space (both form factors may run at once during the exploration),
/// and option-only global shortcuts were disabled outright on macOS
/// 15.0–15.1 — a two-modifier default sidesteps the whole class of bug.
final class BackdropHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let action: () -> Void

    /// Registers `keyCode` + `modifiers` (Carbon codes) system-wide;
    /// nil when the combination is taken or registration fails — the
    /// app still works, toggled by the menu-bar item.
    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                Unmanaged<BackdropHotKey>.fromOpaque(userData).takeUnretainedValue().action()
                return noErr
            },
            1,
            &eventType,
            selfPointer,
            &eventHandler
        )
        guard installed == noErr else { return nil }
        let id = EventHotKeyID(signature: OSType(0x424B_4450) /* 'BKDP' */, id: 1)
        let registered = RegisterEventHotKey(
            keyCode, modifiers, id, GetEventDispatcherTarget(), 0, &hotKeyRef
        )
        guard registered == noErr, hotKeyRef != nil else {
            RemoveEventHandler(eventHandler)
            eventHandler = nil
            return nil
        }
    }

    /// ⌃⌥Space, the backdrop's raise/rest gesture.
    static func controlOptionSpace(action: @escaping () -> Void) -> BackdropHotKey? {
        BackdropHotKey(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(controlKey | optionKey),
            action: action
        )
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}
