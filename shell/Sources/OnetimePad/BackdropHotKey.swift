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
    struct RegistrationFailure: Equatable {
        enum Stage: String { case eventHandler, shortcut }
        let stage: Stage
        let status: OSStatus
    }

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let action: () -> Void

    /// Registers `keyCode` + `modifiers` (Carbon codes) system-wide;
    /// nil when the combination is taken or registration fails. The
    /// app still works: the menu-bar item and the resting card summon
    /// the panel, and ⌘Tab or the Dock icon select the editor window
    /// (ADR-0033).
    init?(keyCode: UInt32, modifiers: UInt32,
          onFailure: (RegistrationFailure) -> Void = { _ in },
          action: @escaping () -> Void) {
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
        guard installed == noErr else {
            onFailure(RegistrationFailure(stage: .eventHandler, status: installed))
            return nil
        }
        let id = EventHotKeyID(signature: OSType(0x424B_4450) /* 'BKDP' */, id: 1)
        let registered = RegisterEventHotKey(
            keyCode, modifiers, id, GetEventDispatcherTarget(),
            UInt32(kEventHotKeyExclusive), &hotKeyRef
        )
        guard registered == noErr, hotKeyRef != nil else {
            RemoveEventHandler(eventHandler)
            eventHandler = nil
            onFailure(RegistrationFailure(stage: .shortcut, status: registered))
            return nil
        }
    }

    /// ⌃⌥Space, the backdrop's raise/rest gesture.
    static func controlOptionSpace(
        onFailure: (RegistrationFailure) -> Void = { _ in },
        action: @escaping () -> Void
    ) -> BackdropHotKey? {
        BackdropHotKey(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(controlKey | optionKey),
            onFailure: onFailure,
            action: action
        )
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}
