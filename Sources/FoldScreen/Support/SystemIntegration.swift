import AppKit
import Carbon.HIToolbox
import ServiceManagement

/// The Escape key, registered only while the effect is on screen.
///
/// Registered lazily rather than at launch: a global hot key steals the key from
/// every other app, so it is only acceptable to hold it while the fold is
/// actually visible and the user may want out.
@MainActor
final class EscapeHotKey {
    /// Identifies this app's one hot key. The handler compares against it so an
    /// unrelated hot key event can never be mistaken for ours.
    private static let signature: OSType = 0x464C_4453  // 'FLDS'
    private static let identifier: UInt32 = 1

    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var onPress: (() -> Void)?

    var isRegistered: Bool { reference != nil }

    func register(onPress: @escaping () -> Void) {
        guard reference == nil else { return }
        self.onPress = onPress

        var specification = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        // The callback is a C function pointer, so the instance travels through
        // user data rather than a capture.
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let context, let event else { return OSStatus(eventNotHandledErr) }
                let hotKey = Unmanaged<EscapeHotKey>.fromOpaque(context).takeUnretainedValue()
                // This handler fires for every hot key press the app receives, not
                // only the one registered here, so check the press really is ours
                // before acting on it.
                guard EscapeHotKey.isOurs(event) else { return OSStatus(eventNotHandledErr) }
                MainActor.assumeIsolated { hotKey.onPress?() }
                return noErr
            }, 1, &specification, Unmanaged.passUnretained(self).toOpaque(), &handler)

        let identifier = EventHotKeyID(
            signature: Self.signature, id: Self.identifier)
        RegisterEventHotKey(
            UInt32(kVK_Escape), 0, identifier, GetApplicationEventTarget(), 0, &reference)
    }

    /// Whether a hot key event carries this app's signature and identifier.
    private static func isOurs(_ event: EventRef) -> Bool {
        var pressed = EventHotKeyID()
        let status = GetEventParameter(
            event, EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil,
            &pressed)
        return status == noErr && pressed.signature == signature && pressed.id == identifier
    }

    func unregister() {
        if let reference {
            UnregisterEventHotKey(reference)
            self.reference = nil
        }
        if let handler {
            RemoveEventHandler(handler)
            self.handler = nil
        }
        onPress = nil
    }

    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }
}

/// "Open at login", backed by the modern service management API.
@MainActor
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// - Returns: an error message when the change could not be applied, or the
    ///   message explaining that macOS wants the user to approve it by hand.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            return "无法修改「登录时打开」：\(error.localizedDescription)"
        }
        // macOS sometimes parks the request until the user confirms it.
        if SMAppService.mainApp.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
            return "已提交请求，请在「系统设置 → 通用 → 登录项」中允许。"
        }
        return nil
    }
}
