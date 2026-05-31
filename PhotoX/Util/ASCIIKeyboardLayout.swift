import AppKit
import Carbon.HIToolbox

/// Resolves keyboard shortcuts independently of the user's active input source.
/// Translates `event.keyCode` + modifiers through the ASCII-capable keyboard
/// layout (typically US) using `UCKeyTranslate`, so the physical key labelled
/// "R" produces "r" whether the user is in English or Russian input mode.
///
/// Falls back to `event.characters` if the layout lookup fails — defensive,
/// since the system always has an ASCII-capable source on a healthy install.
@MainActor
enum ASCIIKeyboardLayout {
    private static var cachedLayout: Data?
    private static var observerInstalled = false

    static func characters(for event: NSEvent) -> String {
        if let chars = translate(keyCode: event.keyCode, flags: event.modifierFlags) {
            return chars
        }
        return event.characters ?? ""
    }

    private static func translate(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> String? {
        guard let data = loadLayoutData() else { return nil }

        // NSEvent's modifier bits sit in the high word of the raw value; UCKeyTranslate's
        // modifierKeyState wants the high byte of Carbon's EventRecord.modifiers field
        // (so cmdKey>>8=1, shiftKey>>8=2, optionKey>>8=8, controlKey>>8=16).
        var carbonMods: UInt32 = 0
        if flags.contains(.shift)   { carbonMods |= UInt32(shiftKey) }
        if flags.contains(.command) { carbonMods |= UInt32(cmdKey) }
        if flags.contains(.option)  { carbonMods |= UInt32(optionKey) }
        if flags.contains(.control) { carbonMods |= UInt32(controlKey) }
        let modKeyState = (carbonMods >> 8) & 0xFF

        return data.withUnsafeBytes { raw -> String? in
            guard let base = raw.baseAddress else { return nil }
            let layoutPtr = base.assumingMemoryBound(to: UCKeyboardLayout.self)
            var deadKeyState: UInt32 = 0
            var actualLength = 0
            var buffer = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(
                layoutPtr,
                keyCode,
                UInt16(kUCKeyActionDown),
                modKeyState,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                buffer.count,
                &actualLength,
                &buffer
            )
            guard status == noErr, actualLength > 0 else { return nil }
            return String(utf16CodeUnits: buffer, count: actualLength)
        }
    }

    private static func loadLayoutData() -> Data? {
        if let cached = cachedLayout { return cached }
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let prop = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let data = Unmanaged<CFData>.fromOpaque(prop).takeUnretainedValue() as Data
        cachedLayout = data
        installInvalidationObserverOnce()
        return data
    }

    private static func installInvalidationObserverOnce() {
        guard !observerInstalled else { return }
        observerInstalled = true
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String),
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in cachedLayout = nil }
        }
    }
}
