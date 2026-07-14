import Carbon.HIToolbox
import Foundation

/// The summon hotkey (⌥Space) as a Carbon `RegisterEventHotKey`
/// registration — the one system-wide key the app claims. Carbon is the
/// deliberate choice: it needs no Accessibility permission (an event
/// tap would) and it consumes the keystroke, so ⌥Space never also types
/// a space into the frontmost app.
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let action: () -> Void

    /// Registers `keyCode` + `modifiers` (Carbon codes) system-wide;
    /// nil when the combination is taken or registration fails — the
    /// app still works, summoned by the menu-bar item.
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
                Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue().action()
                return noErr
            },
            1,
            &eventType,
            selfPointer,
            &eventHandler
        )
        guard installed == noErr else { return nil }
        let id = EventHotKeyID(signature: OSType(0x434F_4D50) /* 'COMP' */, id: 1)
        let registered = RegisterEventHotKey(
            keyCode, modifiers, id, GetEventDispatcherTarget(), 0, &hotKeyRef
        )
        guard registered == noErr, hotKeyRef != nil else {
            RemoveEventHandler(eventHandler)
            eventHandler = nil
            return nil
        }
    }

    /// ⌥Space, the spec's summon gesture (docs/spec/04).
    static func optionSpace(action: @escaping () -> Void) -> GlobalHotKey? {
        GlobalHotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey), action: action)
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}
