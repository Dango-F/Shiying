import AppKit
import Carbon

@MainActor final class HotKey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var onPress: (() -> Void)?
    init() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, pointer in
            guard let pointer else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated { Unmanaged<HotKey>.fromOpaque(pointer).takeUnretainedValue().onPress?() }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    func stop() {
        if let reference { UnregisterEventHotKey(reference); self.reference = nil }
        if let handler { RemoveEventHandler(handler); self.handler = nil }
    }
    func register(code: UInt32, modifiers: UInt32) -> Bool {
        if let reference { UnregisterEventHotKey(reference); self.reference = nil }
        let id = EventHotKeyID(signature: 0x53485947, id: 1)
        return RegisterEventHotKey(code, modifiers, id, GetApplicationEventTarget(), 0, &reference) == noErr
    }
}
