import AppKit
import Carbon.HIToolbox

// Create, use, and shut down on the main thread; retain for the app's lifetime.
final class LabHotKeys {
    private static let signature: OSType = 0x524C_484B // 'RLHK'
    private static let glanceID: UInt32 = 1
    private static let pointerID: UInt32 = 2

    private let onGlance: (Bool) -> Void
    private let onPointer: () -> Void
    private let onFailure: (String) -> Void
    private var eventHandler: EventHandlerRef?
    private var hotKeys: [EventHotKeyRef] = []

    init(
        onGlance: @escaping (Bool) -> Void,
        onPointer: @escaping () -> Void,
        onFailure: @escaping (String) -> Void
    ) {
        self.onGlance = onGlance
        self.onPointer = onPointer
        self.onFailure = onFailure

        var eventTypes = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            ),
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyReleased)
            )
        ]
        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                let hotKeys = Unmanaged<LabHotKeys>.fromOpaque(userData).takeUnretainedValue()
                return hotKeys.handle(event)
            },
            eventTypes.count,
            &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        guard status == noErr, eventHandler != nil else {
            shutdown()
            onFailure("Could not install the hotkey handler (OSStatus \(status)).")
            return
        }

        guard register(keyCode: UInt32(kVK_ANSI_G), id: Self.glanceID, shortcut: "Cmd+Option+G") else {
            return
        }
        _ = register(keyCode: UInt32(kVK_ANSI_P), id: Self.pointerID, shortcut: "Cmd+Option+P")
    }

    private func register(keyCode: UInt32, id: UInt32, shortcut: String) -> Bool {
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            UInt32(cmdKey | optionKey),
            EventHotKeyID(signature: Self.signature, id: id),
            GetEventDispatcherTarget(),
            UInt32(kEventHotKeyExclusive),
            &reference
        )
        if let reference { hotKeys.append(reference) }
        guard status == noErr, reference != nil else {
            shutdown()
            onFailure("Could not register \(shortcut) exclusively (OSStatus \(status)); both shortcuts are disabled.")
            return false
        }
        return true
    }

    private func handle(_ event: EventRef) -> OSStatus {
        var hotKeyID = EventHotKeyID(signature: 0, id: 0)
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard status == noErr else {
            onFailure("Could not read the hotkey event (OSStatus \(status)).")
            return status
        }
        guard hotKeyID.signature == Self.signature else { return OSStatus(eventNotHandledErr) }

        let kind = GetEventKind(event)
        switch hotKeyID.id {
        case Self.glanceID:
            guard kind == UInt32(kEventHotKeyPressed) || kind == UInt32(kEventHotKeyReleased) else {
                return OSStatus(eventNotHandledErr)
            }
            onGlance(kind == UInt32(kEventHotKeyPressed))
        case Self.pointerID:
            if kind == UInt32(kEventHotKeyPressed) { onPointer() }
        default:
            return OSStatus(eventNotHandledErr)
        }
        return noErr
    }

    func shutdown() {
        let references = hotKeys
        hotKeys.removeAll()
        let handler = eventHandler
        eventHandler = nil

        for reference in references {
            let status = UnregisterEventHotKey(reference)
            if status != noErr {
                onFailure("Could not unregister a hotkey (OSStatus \(status)).")
            }
        }
        if let handler {
            let status = RemoveEventHandler(handler)
            if status != noErr {
                onFailure("Could not remove the hotkey handler (OSStatus \(status)).")
            }
        }
    }

    deinit {
        shutdown()
    }
}
