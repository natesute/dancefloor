import Carbon

/// A system-wide keyboard shortcut. Carbon hot keys work without Accessibility permission.
@MainActor
final class HotKey {
    private static var nextID: UInt32 = 1
    private let id: UInt32
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    init(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        self.action = action
        id = Self.nextID
        Self.nextID += 1
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var pressed = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            // Every handler sees every hot key; only act on our own.
            guard pressed.id == hotKey.id else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated { hotKey.action() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        let hotKeyID = EventHotKeyID(signature: OSType(0x4446_4C52), id: id) // "DFLR"
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }
}
