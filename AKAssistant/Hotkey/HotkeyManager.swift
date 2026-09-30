import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Used only when the user picks "Custom shortcut" for dictation.
    static let dictate = Self("dictate", default: .init(.space, modifiers: [.option]))
    /// Used only when the user picks "Custom shortcut" for the AI assistant.
    static let askAI = Self("askAI", default: .init(.space, modifiers: [.option, .shift]))
}

/// What a hotkey does while it's held.
enum HotkeyAction: String, CaseIterable {
    case dictate     // speech -> text pasted at the cursor
    case assistant   // speech -> question for the local AI -> answer panel / voice

    var shortcutName: KeyboardShortcuts.Name {
        switch self {
        case .dictate: return .dictate
        case .assistant: return .askAI
        }
    }
}

/// A push-to-talk key. Hold to record, release to act.
enum HotkeyChoice: String, CaseIterable, Identifiable, Codable {
    case rightOption
    case rightCommand
    case rightControl
    case fn
    case custom
    case off          // only offered for the AI hotkey

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rightOption: return "Right Option (⌥)"
        case .rightCommand: return "Right Command (⌘)"
        case .rightControl: return "Right Control (⌃)"
        case .fn: return "Fn / Globe"
        case .custom: return "Custom shortcut…"
        case .off: return "Off"
        }
    }

    /// Hardware key code for modifier-only choices.
    var keyCode: UInt16? {
        switch self {
        case .rightOption: return 61
        case .rightCommand: return 54
        case .rightControl: return 62
        case .fn: return 63
        case .custom, .off: return nil
        }
    }

    var modifierFlag: NSEvent.ModifierFlags? {
        switch self {
        case .rightOption: return .option
        case .rightCommand: return .command
        case .rightControl: return .control
        case .fn: return .function
        case .custom, .off: return nil
        }
    }
}

/// Detects press and release of the push-to-talk keys anywhere in the system.
/// Modifier-only keys use NSEvent flagsChanged monitors (needs Accessibility permission);
/// custom combos use KeyboardShortcuts' key-down / key-up handlers.
final class HotkeyManager {
    // Called on the main thread (NSEvent monitors and KeyboardShortcuts both deliver there).
    var onPress: (@MainActor (HotkeyAction) -> Void)?
    var onRelease: (@MainActor (HotkeyAction) -> Void)?
    var onCancel: (@MainActor () -> Void)?

    /// While true, Esc cancels the current recording.
    var recordingActive = false

    private var choices: [HotkeyAction: HotkeyChoice] = [.dictate: .rightOption, .assistant: .off]
    private var down: Set<HotkeyAction> = []
    private var escapeMonitors: [Any] = []
    private var modifierMonitors: [Any] = []

    init() {
        for action in HotkeyAction.allCases {
            KeyboardShortcuts.onKeyDown(for: action.shortcutName) { [weak self] in
                guard let self, self.choices[action] == .custom else { return }
                self.press(action)
            }
            KeyboardShortcuts.onKeyUp(for: action.shortcutName) { [weak self] in
                guard let self, self.choices[action] == .custom else { return }
                self.release(action)
            }
        }
        installEscapeMonitors()
    }

    /// Sets both keys at once. If they collide, the AI key is turned off so dictation keeps working.
    func configure(dictate: HotkeyChoice, assistant: HotkeyChoice) {
        for action in down { release(action) }
        let assistantChoice: HotkeyChoice = (assistant == dictate && assistant != .custom) ? .off : assistant
        choices = [.dictate: dictate, .assistant: assistantChoice]

        removeModifierMonitors()
        for action in HotkeyAction.allCases {
            if choices[action] == .custom {
                KeyboardShortcuts.enable(action.shortcutName)
            } else {
                KeyboardShortcuts.disable(action.shortcutName)
            }
        }
        if choices.values.contains(where: { $0.keyCode != nil }) {
            installModifierMonitors()
        }
    }

    // MARK: - Private

    private func installModifierMonitors() {
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            self?.handleFlagsChanged(event)
        }) {
            modifierMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }) {
            modifierMonitors.append(local)
        }
    }

    private func removeModifierMonitors() {
        modifierMonitors.forEach { NSEvent.removeMonitor($0) }
        modifierMonitors.removeAll()
    }

    private func installEscapeMonitors() {
        let escKeyCode: UInt16 = 53
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self, self.recordingActive, event.keyCode == escKeyCode else { return }
            self.cancel()
        }) {
            escapeMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self, self.recordingActive, event.keyCode == escKeyCode else { return event }
            self.cancel()
            return nil
        }) {
            escapeMonitors.append(local)
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        for action in HotkeyAction.allCases {
            guard let choice = choices[action], let code = choice.keyCode, let flag = choice.modifierFlag,
                  event.keyCode == code else { continue }
            if event.modifierFlags.contains(flag) {
                press(action)
            } else {
                release(action)
            }
        }
    }

    private func press(_ action: HotkeyAction) {
        guard !down.contains(action) else { return }
        down.insert(action)
        let handler = onPress
        MainActor.assumeIsolated { handler?(action) }
    }

    private func release(_ action: HotkeyAction) {
        guard down.contains(action) else { return }
        down.remove(action)
        let handler = onRelease
        MainActor.assumeIsolated { handler?(action) }
    }

    private func cancel() {
        down.removeAll()
        let handler = onCancel
        MainActor.assumeIsolated { handler?() }
    }
}
