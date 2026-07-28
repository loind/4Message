import Carbon.HIToolbox

/// Global hotkey qua Carbon `RegisterEventHotKey` — không cần quyền Accessibility
/// (khác với `NSEvent.addGlobalMonitorForEvents`).
final class Hotkey {
    private var ref: EventHotKeyRef?

    // Callback C của Carbon không capture được context, nên handler phải là static.
    // App chỉ đăng ký 1 hotkey duy nhất.
    private static var handler: (() -> Void)?

    init(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        Hotkey.handler = action

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, _ in
                Hotkey.handler?()
                return noErr
            },
            1, &spec, nil, nil
        )

        let id = EventHotKeyID(signature: OSType(0x4D42_5231), id: 1)  // 'MBR1'
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
    }
}
