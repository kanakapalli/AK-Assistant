import AppKit
import ApplicationServices

/// Puts text into whatever text field has focus in the frontmost app.
enum TextInserter {
    enum Result {
        case pasted
        case copiedOnly
    }

    /// Pastes via the clipboard + Cmd+V, then restores the previous clipboard contents.
    /// If nothing has keyboard focus, the text is left on the clipboard instead.
    @discardableResult
    static func insert(_ text: String, restoreClipboard: Bool) -> Result {
        let pasteboard = NSPasteboard.general

        guard hasFocusedElement() else {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            return .copiedOnly
        }

        let saved = restoreClipboard ? snapshot(pasteboard) : []

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let ourChangeCount = pasteboard.changeCount

        sendPasteShortcut()

        if restoreClipboard {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                // Skip if something else wrote to the clipboard in the meantime.
                guard pasteboard.changeCount == ourChangeCount else { return }
                restore(saved, to: pasteboard)
            }
        }
        return .pasted
    }

    /// Fallback for fields that block paste: types the text as synthetic keystrokes.
    static func typeText(_ text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let units = Array(text.utf16)
        var index = 0
        while index < units.count {
            let chunk = Array(units[index..<min(index + 20, units.count)])
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            chunk.withUnsafeBufferPointer { buffer in
                down?.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
                up?.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            }
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
            index += 20
        }
    }

    // MARK: - Private

    private static func sendPasteShortcut() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// True when some UI element in the frontmost app has keyboard focus.
    private static func hasFocusedElement() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused)
        switch error {
        case .success: return focused != nil
        case .noValue: return false            // nothing has focus -> copy only
        default: return true                   // app doesn't report focus (some Electron apps) -> try pasting
        }
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var entry: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { entry[type] = data }
            }
            return entry
        }
    }

    private static func restore(_ items: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let restored = items.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(restored)
    }
}
