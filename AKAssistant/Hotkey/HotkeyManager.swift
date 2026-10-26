import AppKit
import KeyboardShortcuts
import os

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

    /// Short name for tight spaces like the popup ("⌥", "Fn").
    var shortTitle: String {
        switch self {
        case .rightOption: return "⌥"
        case .rightCommand: return "⌘"
        case .rightControl: return "⌃"
        case .fn: return "Fn"
        case .custom: return "your shortcut"
        case .off: return "—"
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

    /// The device-dependent bit for this exact key (from IOKit's NX_DEVICE*KEYMASK). Unlike
    /// `.option`, it's only set by the *right* Option key, so holding left ⌥ doesn't confuse it.
    var deviceMask: UInt? {
        switch self {
        case .rightOption: return 0x0000_0040    // NX_DEVICERALTKEYMASK
        case .rightCommand: return 0x0000_0010   // NX_DEVICERCMDKEYMASK
        case .rightControl: return 0x0000_2000   // NX_DEVICERCTLKEYMASK
        case .fn, .custom, .off: return nil
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
    /// Two quick taps of the same key (nothing else pressed in between). The second press is
    /// consumed: it doesn't reach onPress / onRelease.
    var onDoubleTap: (@MainActor (HotkeyAction) -> Void)?
    /// Which keys listen for a double tap (only dictation, for meetings). Others never swallow a press.
    var doubleTapActions: Set<HotkeyAction> = []

    /// While true, Esc cancels the current recording.
    var recordingActive = false

    private var choices: [HotkeyAction: HotkeyChoice] = [.dictate: .rightOption, .assistant: .off]
    private var down: Set<HotkeyAction> = []
    private var escapeMonitors: [Any] = []
    private var modifierMonitors: [Any] = []

    // Double-tap detection.
    /// A press shorter than this counts as a tap.
    private let tapMaxHold: TimeInterval = 0.3
    /// The second tap must start within this long of the first one ending.
    private let doubleTapWindow: TimeInterval = 0.4
    private var pressedAt: [HotkeyAction: Date] = [:]
    private var lastTapEnded: [HotkeyAction: Date] = [:]
    /// Another key was used while the hotkey was down (e.g. ⌥← to jump a word): not a tap.
    private var interrupted: Set<HotkeyAction> = []
    /// Presses that completed a double tap; their release is swallowed.
    private var consumed: Set<HotkeyAction> = []

    /// What the key monitors saw last, for Settings › Hotkey check.
    private(set) var lastEvent: (text: String, at: Date)?
    var isDown: Set<HotkeyAction> { down }
    var monitorCount: Int { modifierMonitors.count }

    private let log = Logger(subsystem: "com.natfirst.akassistant", category: "Hotkey")

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
            guard let self else { return }
            self.markInterrupted()
            guard self.recordingActive, event.keyCode == escKeyCode else { return }
            self.cancel()
        }) {
            escapeMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self else { return event }
            self.markInterrupted()
            guard self.recordingActive, event.keyCode == escKeyCode else { return event }
            self.cancel()
            return nil
        }) {
            escapeMonitors.append(local)
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        // A different modifier changed while a hotkey is down (e.g. Shift): not a clean tap.
        let ours = HotkeyAction.allCases.compactMap { choices[$0]?.keyCode }
        if !ours.contains(event.keyCode) { markInterrupted() }
        for action in HotkeyAction.allCases {
            guard let choice = choices[action], let code = choice.keyCode, let flag = choice.modifierFlag,
                  event.keyCode == code else { continue }
            // Prefer the key's own bit: `.option` is also set by the *left* Option key.
            let isDownNow: Bool
            if let mask = choice.deviceMask {
                isDownNow = event.modifierFlags.rawValue & mask != 0
            } else {
                isDownNow = event.modifierFlags.contains(flag)
            }
            lastEvent = ("\(choice.title) \(isDownNow ? "down" : "up")", Date())
            if isDownNow {
                // Already "down" means macOS never told us it was released (e.g. it went up while a
                // password field or permission prompt had the keyboard). Finish that press first,
                // otherwise this press would be ignored and the key would seem dead.
                if down.contains(action) {
                    log.info("Missed key-up for \(action.rawValue, privacy: .public); recovering")
                    release(action)
                }
                press(action)
            } else {
                release(action)
            }
        }
    }

    /// Forgets any key state and re-installs the monitors (Settings › Hotkey check › Reset).
    func reset() {
        log.info("Hotkeys reset")
        consumed.removeAll()
        lastTapEnded.removeAll()
        interrupted.removeAll()
        down.removeAll()
        configure(dictate: choices[.dictate] ?? .rightOption, assistant: choices[.assistant] ?? .off)
    }

    private func markInterrupted() {
        interrupted.formUnion(down)
        lastTapEnded.removeAll()
    }

    private func press(_ action: HotkeyAction) {
        guard !down.contains(action) else { return }
        down.insert(action)
        let now = Date()
        pressedAt[action] = now
        interrupted.remove(action)

        log.debug("Press \(action.rawValue, privacy: .public)")
        // Second quick tap: report a double tap instead of a normal press.
        if let ended = lastTapEnded[action], now.timeIntervalSince(ended) < doubleTapWindow, doubleTapActions.contains(action) {
            lastTapEnded[action] = nil
            consumed.insert(action)
            let handler = onDoubleTap
            MainActor.assumeIsolated { handler?(action) }
            return
        }
        let handler = onPress
        MainActor.assumeIsolated { handler?(action) }
    }

    private func release(_ action: HotkeyAction) {
        guard down.contains(action) else { return }
        down.remove(action)
        if consumed.remove(action) != nil { return }   // the second tap of a double tap
        log.debug("Release \(action.rawValue, privacy: .public)")

        let wasTap = !interrupted.contains(action)
            && Date().timeIntervalSince(pressedAt[action] ?? .distantPast) < tapMaxHold
        lastTapEnded[action] = wasTap ? Date() : nil

        let handler = onRelease
        MainActor.assumeIsolated { handler?(action) }
    }

    private func cancel() {
        consumed.removeAll()
        lastTapEnded.removeAll()
        down.removeAll()
        let handler = onCancel
        MainActor.assumeIsolated { handler?() }
    }
}
