import AppKit
import ApplicationServices
import Carbon.HIToolbox
import os

/// Puts text into whatever text field has focus in the frontmost app.
///
/// Two ways, tried in order:
/// 1. Accessibility: write the text straight into the focused field (native Mac apps). No clipboard
///    involved, and we check the field's value afterwards to be sure it really changed.
/// 2. Clipboard + ⌘V: works in browsers, Electron apps (Slack, VS Code, Notion), Office and most others.
///    This is sent even when the app doesn't tell Accessibility which field is focused; many apps
///    (Chrome, Electron, Java) don't, and skipping the paste was the reason text often didn't appear.
enum TextInserter {
    enum Result: Equatable {
        /// Written straight into the focused field.
        case inserted
        /// ⌘V was sent. `focusConfirmed` is false when the app didn't report a focused field, so we
        /// can't be sure it landed; the text is then also left on the clipboard.
        case pasted(focusConfirmed: Bool)
        /// Nothing could be sent; the text is on the clipboard.
        case copiedOnly(CopyReason)

        var reachedApp: Bool {
            if case .copiedOnly = self { return false }
            return true
        }
    }

    /// Why the text went to the clipboard instead of into the app.
    enum CopyReason: Equatable {
        /// macOS isn't letting this copy of the app control the keyboard. Common after rebuilding or
        /// moving the app: the old Accessibility entry still looks on but no longer applies.
        case noAccessibility
        /// A password field or an app with "Secure Keyboard Entry" (Terminal, password managers)
        /// is blocking simulated typing.
        case secureInput
    }

    private static let log = Logger(subsystem: "com.natfirst.akassistant", category: "Insert")

    @discardableResult
    static func insert(_ text: String, restoreClipboard: Bool) -> Result {
        let pasteboard = NSPasteboard.general

        guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
            log.error("Can't paste: \(Permissions.summary, privacy: .public)")
            if !CGPreflightPostEventAccess() { _ = CGRequestPostEventAccess() }
            copy(text, to: pasteboard)
            return .copiedOnly(.noAccessibility)
        }
        if IsSecureEventInputEnabled() {
            copy(text, to: pasteboard)
            return .copiedOnly(.secureInput)
        }

        let focus = focusedElement()
        if let element = focus.element, insertDirectly(text, into: element) {
            log.info("Inserted via Accessibility")
            return .inserted
        }

        let confirmed = focus.element != nil
        // If we couldn't see a focused field, keep the text on the clipboard so ⌘V still works by hand.
        let shouldRestore = restoreClipboard && confirmed
        let saved = shouldRestore ? snapshot(pasteboard) : []
        copy(text, to: pasteboard)
        let ourChangeCount = pasteboard.changeCount

        sendPasteShortcut()
        log.info("Sent ⌘V (focused field reported: \(confirmed), AX status \(focus.status.rawValue))")

        if shouldRestore {
            // Give slower apps (browsers, Electron, Office) time to read the clipboard before it's
            // put back; restoring too early makes them paste your old clipboard instead.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                // Skip if something else wrote to the clipboard in the meantime.
                guard pasteboard.changeCount == ourChangeCount else { return }
                restore(saved, to: pasteboard)
            }
        }
        return .pasted(focusConfirmed: confirmed)
    }

    /// Fallback for fields that block paste: types the text as synthetic keystrokes.
    static func typeText(_ text: String) {
        let source = CGEventSource(stateID: .privateState)
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

    /// The focused UI element in the frontmost app, asked of that app directly (more reliable than
    /// the system-wide query, which many apps answer with "no value").
    private static func focusedElement() -> (element: AXUIElement?, status: AXError) {
        var status = AXError.noValue
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            let app = AXUIElementCreateApplication(pid)
            var value: CFTypeRef?
            status = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value)
            if status == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                return ((value as! AXUIElement), status)
            }
        }
        let systemWide = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        status = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &value)
        if status == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
            return ((value as! AXUIElement), status)
        }
        return (nil, status)
    }

    /// Replaces the selection (or inserts at the cursor) through Accessibility, and only reports
    /// success if the field's text actually changed. Some apps accept the call but ignore it.
    private static func insertDirectly(_ text: String, into element: AXUIElement) -> Bool {
        guard let before = stringValue(of: element) else { return false }   // can't verify -> use ⌘V
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue else { return false }
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success
        else { return false }
        guard let after = stringValue(of: element) else { return false }
        return after != before && after.contains(text)
    }

    private static func stringValue(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func copy(_ text: String, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private static func sendPasteShortcut() {
        sendCommandKey(kVK_ANSI_V)
    }

    /// Presses ⌘ + a key (⌘A, ⌘C, ⌘V) in the frontmost app.
    static func sendCommandKey(_ keyCode: Int) {
        // A private event source ignores keys you're physically still holding (like the hotkey's
        // Option or Command), so the app receives exactly ⌘V and not ⌥⌘V.
        let source = CGEventSource(stateID: .privateState)
        let key = CGKeyCode(keyCode)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        usleep(12_000)   // some apps drop a key-up that arrives in the same instant as its key-down
        up?.post(tap: .cghidEventTap)
    }

    static func snapshot(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var entry: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { entry[type] = data }
            }
            return entry
        }
    }

    static func restore(_ items: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard) {
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
