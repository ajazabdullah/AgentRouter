import AppKit
import Carbon
import RouterCore

private let routerHotKeySignature: OSType = 0x41525452

private func routerHotKeyHandler(_ next: EventHandlerCallRef?, _ event: EventRef?, _ context: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let context else { return OSStatus(eventNotHandledErr) }
    var identifier = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                   MemoryLayout<EventHotKeyID>.size, nil, &identifier)
    guard status == noErr, identifier.signature == routerHotKeySignature else { return OSStatus(eventNotHandledErr) }
    let shortcuts = Unmanaged<GlobalShortcuts>.fromOpaque(context).takeUnretainedValue()
    let id = identifier.id
    Task { @MainActor in shortcuts.onPress(id) }
    return noErr
}

/// Registration is managed by AppDelegate on the main thread. No event tap,
/// Accessibility permission, media-key interception, or system preference changes.
final class GlobalShortcuts: @unchecked Sendable {
    let onPress: @MainActor @Sendable (UInt32) -> Void
    private var handler: EventHandlerRef?
    private var keys: [UInt32: EventHotKeyRef] = [:]

    init(onPress: @escaping @MainActor @Sendable (UInt32) -> Void) throws {
        self.onPress = onPress
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), routerHotKeyHandler, 1, &event,
                                        Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { throw RouterError.message("Could not install keyboard shortcuts (\(status)).") }
        try register(id: 0, key: UInt32(kVK_ANSI_R), modifiers: UInt32(cmdKey | optionKey))
    }

    func setCLIKeysEnabled(_ enabled: Bool) throws {
        for id: UInt32 in [1, 2, 3] {
            if let key = keys.removeValue(forKey: id) { UnregisterEventHotKey(key) }
        }
        guard enabled else { return }
        do {
            try register(id: 1, key: UInt32(kVK_F7), modifiers: 0)
            try register(id: 2, key: UInt32(kVK_F8), modifiers: 0)
            try register(id: 3, key: UInt32(kVK_F9), modifiers: 0)
        } catch {
            for id: UInt32 in [1, 2, 3] {
                if let key = keys.removeValue(forKey: id) { UnregisterEventHotKey(key) }
            }
            throw error
        }
    }

    private func register(id: UInt32, key: UInt32, modifiers: UInt32) throws {
        var reference: EventHotKeyRef?
        let result = RegisterEventHotKey(key, modifiers, EventHotKeyID(signature: routerHotKeySignature, id: id),
                                        GetApplicationEventTarget(), 0, &reference)
        guard result == noErr, let reference else {
            throw RouterError.message("Shortcut \(id == 0 ? "⌥⌘R" : "F\(id + 6)") could not be registered (\(result)); another application may already use it.")
        }
        keys[id] = reference
    }

    deinit {
        for key in keys.values { UnregisterEventHotKey(key) }
        if let handler { RemoveEventHandler(handler) }
    }
}
