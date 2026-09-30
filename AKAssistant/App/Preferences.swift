import Foundation
import Observation

/// User settings, persisted in UserDefaults.
/// `@Observable` lets SwiftUI views redraw only when a property they read changes.
@MainActor
@Observable
final class Preferences {
    private let defaults = UserDefaults.standard

    private enum Key {
        static let onboarded = "onboarded"
        static let selectedModelID = "selectedModelID"
        static let hotkey = "hotkey"
        static let language = "language"
        static let removeFillers = "removeFillers"
        static let playSounds = "playSounds"
        static let historyRetentionDays = "historyRetentionDays"
        static let restoreClipboard = "restoreClipboard"
        static let useNeuralEngine = "useNeuralEngine"
        static let assistantHotkey = "assistantHotkey"
        static let chatModelID = "chatModelID"
        static let voiceModelID = "voiceModelID"
        static let voice = "voice"
        static let replyStyle = "replyStyle"
    }

    var onboarded: Bool { didSet { defaults.set(onboarded, forKey: Key.onboarded) } }
    var selectedModelID: String { didSet { defaults.set(selectedModelID, forKey: Key.selectedModelID) } }
    var hotkey: HotkeyChoice { didSet { defaults.set(hotkey.rawValue, forKey: Key.hotkey) } }
    /// ISO language code, or "auto" for detection.
    var language: String { didSet { defaults.set(language, forKey: Key.language) } }
    var removeFillers: Bool { didSet { defaults.set(removeFillers, forKey: Key.removeFillers) } }
    var playSounds: Bool { didSet { defaults.set(playSounds, forKey: Key.playSounds) } }
    /// 0 = keep forever, -1 = don't save history, otherwise number of days.
    var historyRetentionDays: Int { didSet { defaults.set(historyRetentionDays, forKey: Key.historyRetentionDays) } }
    var restoreClipboard: Bool { didSet { defaults.set(restoreClipboard, forKey: Key.restoreClipboard) } }
    /// false = run Whisper on the GPU (loads in seconds). true = Neural Engine (lower power, but the
    /// first load compiles the model and can take many minutes for the large models).
    var useNeuralEngine: Bool { didSet { defaults.set(useNeuralEngine, forKey: Key.useNeuralEngine) } }

    // MARK: AI assistant
    /// Hold this key to ask the AI a question. `.off` disables the assistant.
    var assistantHotkey: HotkeyChoice { didSet { defaults.set(assistantHotkey.rawValue, forKey: Key.assistantHotkey) } }
    var chatModelID: String { didSet { defaults.set(chatModelID, forKey: Key.chatModelID) } }
    var voiceModelID: String { didSet { defaults.set(voiceModelID, forKey: Key.voiceModelID) } }
    /// Qwen3-TTS speaker, e.g. "ryan".
    var voice: String { didSet { defaults.set(voice, forKey: Key.voice) } }
    var replyStyle: ReplyStyle { didSet { defaults.set(replyStyle.rawValue, forKey: Key.replyStyle) } }

    init() {
        // Use a local constant: `self` can't be read until every stored property has a value.
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            Key.onboarded: false,
            Key.selectedModelID: ModelCatalog.defaultModel.id,
            Key.hotkey: HotkeyChoice.rightOption.rawValue,
            Key.language: "auto",
            Key.removeFillers: true,
            Key.playSounds: true,
            Key.historyRetentionDays: 0,
            Key.restoreClipboard: true,
            Key.useNeuralEngine: false,
            Key.assistantHotkey: HotkeyChoice.rightCommand.rawValue,
            Key.chatModelID: AssistantCatalog.defaultChatModel.id,
            Key.voiceModelID: AssistantCatalog.defaultVoiceModel.id,
            Key.voice: "ryan",
            Key.replyStyle: ReplyStyle.panelAndVoice.rawValue,
        ])
        onboarded = defaults.bool(forKey: Key.onboarded)
        selectedModelID = defaults.string(forKey: Key.selectedModelID) ?? ModelCatalog.defaultModel.id
        hotkey = HotkeyChoice(rawValue: defaults.string(forKey: Key.hotkey) ?? "") ?? .rightOption
        language = defaults.string(forKey: Key.language) ?? "auto"
        removeFillers = defaults.bool(forKey: Key.removeFillers)
        playSounds = defaults.bool(forKey: Key.playSounds)
        historyRetentionDays = defaults.integer(forKey: Key.historyRetentionDays)
        restoreClipboard = defaults.bool(forKey: Key.restoreClipboard)
        useNeuralEngine = defaults.bool(forKey: Key.useNeuralEngine)
        assistantHotkey = HotkeyChoice(rawValue: defaults.string(forKey: Key.assistantHotkey) ?? "") ?? .rightCommand
        chatModelID = defaults.string(forKey: Key.chatModelID) ?? AssistantCatalog.defaultChatModel.id
        voiceModelID = defaults.string(forKey: Key.voiceModelID) ?? AssistantCatalog.defaultVoiceModel.id
        voice = defaults.string(forKey: Key.voice) ?? "ryan"
        replyStyle = ReplyStyle(rawValue: defaults.string(forKey: Key.replyStyle) ?? "") ?? .panelAndVoice
    }

    var selectedModel: SpeechModel {
        ModelCatalog.model(id: selectedModelID) ?? ModelCatalog.defaultModel
    }

    var chatModel: ChatModel {
        AssistantCatalog.chatModel(id: chatModelID) ?? AssistantCatalog.defaultChatModel
    }

    var voiceModel: VoiceModel {
        AssistantCatalog.voiceModel(id: voiceModelID) ?? AssistantCatalog.defaultVoiceModel
    }

    var assistantEnabled: Bool { assistantHotkey != .off }

    /// nil means auto-detect.
    var languageCode: String? {
        language == "auto" ? nil : language
    }

    static let languages: [(code: String, name: String)] = [
        ("auto", "Auto-detect"),
        ("en", "English"),
        ("hi", "Hindi"),
        ("te", "Telugu"),
        ("ta", "Tamil"),
        ("kn", "Kannada"),
        ("mr", "Marathi"),
        ("bn", "Bengali"),
        ("es", "Spanish"),
        ("fr", "French"),
        ("de", "German"),
        ("ja", "Japanese"),
        ("zh", "Chinese"),
    ]
}
