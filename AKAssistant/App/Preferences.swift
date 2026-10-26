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
        static let showLiveTranscript = "showLiveTranscript"
        static let cancelSpeakerEcho = "cancelSpeakerEcho"
        static let muteWhileDictating = "muteWhileDictating"
        static let macCommandsEnabled = "macCommandsEnabled"
        static let aiCommandsEnabled = "aiCommandsEnabled"
        static let grammarFixEnabled = "grammarFixEnabled"
        static let textActions = "textActions"
        static let confirmRiskyCommands = "confirmRiskyCommands"
        static let seenLearn = "seenLearn"
        static let meetingDoubleTap = "meetingDoubleTap"
        static let meetingCaptureSystemAudio = "meetingCaptureSystemAudio"
        static let meetingKeepAudio = "meetingKeepAudio"
        static let meetingVoiceProcessing = "meetingVoiceProcessing"
        static let meetingCleanupPass = "meetingCleanupPass"
        static let meetingIdentifySpeakers = "meetingIdentifySpeakers"
        static let meetingFinalModelID = "meetingFinalModelID"
        static let meetingLanguage = "meetingLanguage"
        static let meetingLiveTranscript = "meetingLiveTranscript"
        static let meetingRemoveEcho = "meetingRemoveEcho"
        static let meetingSpeechSensitivity = "meetingSpeechSensitivity"
        static let meetingSpeakerCount = "meetingSpeakerCount"
        static let meetingNotesModelID = "meetingNotesModelID"
        static let meetingNotesDetail = "meetingNotesDetail"
        static let meetingWriteNotes = "meetingWriteNotes"
        static let meetingMaxHours = "meetingMaxHours"
        static let memoryEnabled = "memoryEnabled"
        static let memoryIndexMeetings = "memoryIndexMeetings"
        static let memoryIndexHistory = "memoryIndexHistory"
        static let commandMatching = "commandMatching"
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
    /// Show a live, rough transcript in the popup while the hotkey is held.
    var showLiveTranscript: Bool { didSet { defaults.set(showLiveTranscript, forKey: Key.showLiveTranscript) } }
    /// Remove the Mac's own speaker sound from the microphone while dictating (echo cancellation).
    var cancelSpeakerEcho: Bool { didSet { defaults.set(cancelSpeakerEcho, forKey: Key.cancelSpeakerEcho) } }
    /// Mute the Mac's sound while a hotkey is held, so videos and music can't reach the microphone.
    var muteWhileDictating: Bool { didSet { defaults.set(muteWhileDictating, forKey: Key.muteWhileDictating) } }

    // MARK: AI assistant
    /// Hold this key to ask the AI a question. `.off` disables the assistant.
    var assistantHotkey: HotkeyChoice { didSet { defaults.set(assistantHotkey.rawValue, forKey: Key.assistantHotkey) } }
    var chatModelID: String { didSet { defaults.set(chatModelID, forKey: Key.chatModelID) } }
    var voiceModelID: String { didSet { defaults.set(voiceModelID, forKey: Key.voiceModelID) } }
    /// Qwen3-TTS speaker, e.g. "ryan".
    var voice: String { didSet { defaults.set(voice, forKey: Key.voice) } }
    var replyStyle: ReplyStyle { didSet { defaults.set(replyStyle.rawValue, forKey: Key.replyStyle) } }

    // MARK: Mac commands
    /// The AI hotkey also understands commands like "open Xcode" or "set a timer for 10 minutes".
    var macCommandsEnabled: Bool { didSet { defaults.set(macCommandsEnabled, forKey: Key.macCommandsEnabled) } }
    /// Let the AI model turn unusual phrasings (or other languages) into commands.
    var aiCommandsEnabled: Bool { didSet { defaults.set(aiCommandsEnabled, forKey: Key.aiCommandsEnabled) } }
    /// Quit, lock, sleep, empty Trash… wait for a click on Run. Off by default: commands run right away.
    var confirmRiskyCommands: Bool { didSet { defaults.set(confirmRiskyCommands, forKey: Key.confirmRiskyCommands) } }
    /// Writing tools on or off: shortcuts that rewrite the focused text field with the AI.
    var grammarFixEnabled: Bool { didSet { defaults.set(grammarFixEnabled, forKey: Key.grammarFixEnabled) } }
    /// The writing tools (fix grammar, write as email, …), each with its prompt. Shortcuts are kept by KeyboardShortcuts.
    var textActions: [TextAction] { didSet { defaults.set(TextActionCatalog.encode(textActions), forKey: Key.textActions) } }
    /// Learn has been opened at least once (hides its "New" badge).
    var seenLearn: Bool { didSet { defaults.set(seenLearn, forKey: Key.seenLearn) } }

    // MARK: Meetings
    /// Double-tap the dictation key to start recording a meeting; press it again to stop.
    var meetingDoubleTap: Bool { didSet { defaults.set(meetingDoubleTap, forKey: Key.meetingDoubleTap) } }
    /// Also record what the Mac plays (the other people on a call). Needs Screen & System Audio Recording.
    var meetingCaptureSystemAudio: Bool { didSet { defaults.set(meetingCaptureSystemAudio, forKey: Key.meetingCaptureSystemAudio) } }
    /// Keep each meeting's audio so it can be played back in Meetings.
    var meetingKeepAudio: Bool { didSet { defaults.set(meetingKeepAudio, forKey: Key.meetingKeepAudio) } }
    /// Apple's voice processing on the mic: noise suppression and echo cancellation.
    var meetingVoiceProcessing: Bool { didSet { defaults.set(meetingVoiceProcessing, forKey: Key.meetingVoiceProcessing) } }
    /// After the meeting, redo the transcript from the separate mic / Mac tracks, cut at pauses.
    var meetingCleanupPass: Bool { didSet { defaults.set(meetingCleanupPass, forKey: Key.meetingCleanupPass) } }
    /// Label who said what ("You", "Speaker 1"…) during the clean-up pass.
    var meetingIdentifySpeakers: Bool { didSet { defaults.set(meetingIdentifySpeakers, forKey: Key.meetingIdentifySpeakers) } }
    /// Speech model for the clean-up pass. "" = the dictation model.
    var meetingFinalModelID: String { didSet { defaults.set(meetingFinalModelID, forKey: Key.meetingFinalModelID) } }
    /// Language spoken in meetings: "same" = the dictation language, "auto", or an ISO code.
    var meetingLanguage: String { didSet { defaults.set(meetingLanguage, forKey: Key.meetingLanguage) } }
    /// Transcribe while the meeting is going (off saves battery; the clean-up pass writes it at the end).
    var meetingLiveTranscript: Bool { didSet { defaults.set(meetingLiveTranscript, forKey: Key.meetingLiveTranscript) } }
    /// Drop mic lines that only repeat the call coming out of the speakers.
    var meetingRemoveEcho: Bool { didSet { defaults.set(meetingRemoveEcho, forKey: Key.meetingRemoveEcho) } }
    /// How readily sound counts as speech in the clean-up pass.
    var meetingSpeechSensitivity: SpeechSensitivity { didSet { defaults.set(meetingSpeechSensitivity.rawValue, forKey: Key.meetingSpeechSensitivity) } }
    /// People in the meeting including you. 0 = work it out automatically.
    var meetingSpeakerCount: Int { didSet { defaults.set(meetingSpeakerCount, forKey: Key.meetingSpeakerCount) } }
    /// AI model that writes meeting notes. "" = the AI assistant's model.
    var meetingNotesModelID: String { didSet { defaults.set(meetingNotesModelID, forKey: Key.meetingNotesModelID) } }
    var meetingNotesDetail: NotesDetail { didSet { defaults.set(meetingNotesDetail.rawValue, forKey: Key.meetingNotesDetail) } }
    /// Write a summary and to-dos automatically when a meeting ends.
    var meetingWriteNotes: Bool { didSet { defaults.set(meetingWriteNotes, forKey: Key.meetingWriteNotes) } }
    /// Recording stops by itself after this many hours.
    var meetingMaxHours: Int { didSet { defaults.set(meetingMaxHours, forKey: Key.meetingMaxHours) } }

    // MARK: Search & memory
    /// Smart search & memory (downloads the search model the first time).
    var memoryEnabled: Bool { didSet { defaults.set(memoryEnabled, forKey: Key.memoryEnabled) } }
    var memoryIndexMeetings: Bool { didSet { defaults.set(memoryIndexMeetings, forKey: Key.memoryIndexMeetings) } }
    var memoryIndexHistory: Bool { didSet { defaults.set(memoryIndexHistory, forKey: Key.memoryIndexHistory) } }
    /// Understand Mac commands phrased any way, in any language, by meaning.
    var commandMatching: CommandMatching { didSet { defaults.set(commandMatching.rawValue, forKey: Key.commandMatching) } }

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
            Key.showLiveTranscript: true,
            Key.cancelSpeakerEcho: false,
            Key.muteWhileDictating: true,
            Key.assistantHotkey: HotkeyChoice.rightCommand.rawValue,
            Key.chatModelID: AssistantCatalog.defaultChatModel.id,
            Key.voiceModelID: AssistantCatalog.defaultVoiceModel.id,
            Key.voice: "ryan",
            Key.replyStyle: ReplyStyle.panelAndVoice.rawValue,
            Key.macCommandsEnabled: true,
            Key.aiCommandsEnabled: true,
            Key.grammarFixEnabled: true,
            Key.confirmRiskyCommands: false,
            Key.seenLearn: false,
            Key.meetingDoubleTap: true,
            Key.meetingCaptureSystemAudio: true,
            Key.meetingKeepAudio: true,
            Key.meetingVoiceProcessing: true,
            Key.meetingCleanupPass: true,
            Key.meetingIdentifySpeakers: true,
            Key.meetingFinalModelID: "",
            Key.meetingLanguage: "same",
            Key.meetingLiveTranscript: true,
            Key.meetingRemoveEcho: true,
            Key.meetingSpeechSensitivity: SpeechSensitivity.normal.rawValue,
            Key.meetingSpeakerCount: 0,
            Key.meetingNotesModelID: "",
            Key.meetingNotesDetail: NotesDetail.standard.rawValue,
            Key.meetingWriteNotes: true,
            Key.meetingMaxHours: 4,
            Key.memoryEnabled: false,
            Key.memoryIndexMeetings: true,
            Key.memoryIndexHistory: true,
            Key.commandMatching: CommandMatching.run.rawValue,
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
        showLiveTranscript = defaults.bool(forKey: Key.showLiveTranscript)
        cancelSpeakerEcho = defaults.bool(forKey: Key.cancelSpeakerEcho)
        // Once: switch echo cancellation off for everyone who got it on by default. It delays the start
        // of every recording and can make the voice too quiet; muting handles background sound instead.
        if !defaults.bool(forKey: "echoCancellationDefaultOff") {
            cancelSpeakerEcho = false
            defaults.set(false, forKey: Key.cancelSpeakerEcho)
            defaults.set(true, forKey: "echoCancellationDefaultOff")
        }
        muteWhileDictating = defaults.bool(forKey: Key.muteWhileDictating)
        assistantHotkey = HotkeyChoice(rawValue: defaults.string(forKey: Key.assistantHotkey) ?? "") ?? .rightCommand
        chatModelID = defaults.string(forKey: Key.chatModelID) ?? AssistantCatalog.defaultChatModel.id
        voiceModelID = defaults.string(forKey: Key.voiceModelID) ?? AssistantCatalog.defaultVoiceModel.id
        voice = defaults.string(forKey: Key.voice) ?? "ryan"
        replyStyle = ReplyStyle(rawValue: defaults.string(forKey: Key.replyStyle) ?? "") ?? .panelAndVoice
        macCommandsEnabled = defaults.bool(forKey: Key.macCommandsEnabled)
        aiCommandsEnabled = defaults.bool(forKey: Key.aiCommandsEnabled)
        grammarFixEnabled = defaults.bool(forKey: Key.grammarFixEnabled)
        textActions = TextActionCatalog.load(from: defaults.data(forKey: Key.textActions))
        confirmRiskyCommands = defaults.bool(forKey: Key.confirmRiskyCommands)
        seenLearn = defaults.bool(forKey: Key.seenLearn)
        meetingDoubleTap = defaults.bool(forKey: Key.meetingDoubleTap)
        meetingCaptureSystemAudio = defaults.bool(forKey: Key.meetingCaptureSystemAudio)
        meetingKeepAudio = defaults.bool(forKey: Key.meetingKeepAudio)
        meetingVoiceProcessing = defaults.bool(forKey: Key.meetingVoiceProcessing)
        meetingCleanupPass = defaults.bool(forKey: Key.meetingCleanupPass)
        meetingIdentifySpeakers = defaults.bool(forKey: Key.meetingIdentifySpeakers)
        meetingFinalModelID = defaults.string(forKey: Key.meetingFinalModelID) ?? ""
        meetingLanguage = defaults.string(forKey: Key.meetingLanguage) ?? "same"
        meetingLiveTranscript = defaults.bool(forKey: Key.meetingLiveTranscript)
        meetingRemoveEcho = defaults.bool(forKey: Key.meetingRemoveEcho)
        meetingSpeechSensitivity = SpeechSensitivity(rawValue: defaults.string(forKey: Key.meetingSpeechSensitivity) ?? "") ?? .normal
        meetingSpeakerCount = defaults.integer(forKey: Key.meetingSpeakerCount)
        meetingNotesModelID = defaults.string(forKey: Key.meetingNotesModelID) ?? ""
        meetingNotesDetail = NotesDetail(rawValue: defaults.string(forKey: Key.meetingNotesDetail) ?? "") ?? .standard
        meetingWriteNotes = defaults.bool(forKey: Key.meetingWriteNotes)
        meetingMaxHours = defaults.integer(forKey: Key.meetingMaxHours)
        memoryEnabled = defaults.bool(forKey: Key.memoryEnabled)
        memoryIndexMeetings = defaults.bool(forKey: Key.memoryIndexMeetings)
        memoryIndexHistory = defaults.bool(forKey: Key.memoryIndexHistory)
        commandMatching = CommandMatching(rawValue: defaults.string(forKey: Key.commandMatching) ?? "") ?? .run
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

    /// The speech model for the meeting clean-up pass, if one other than the dictation model is picked.
    var meetingFinalModel: SpeechModel? {
        meetingFinalModelID.isEmpty ? nil : ModelCatalog.model(id: meetingFinalModelID)
    }

    /// The AI model for meeting notes, if one other than the assistant's is picked.
    var meetingNotesModel: ChatModel? {
        meetingNotesModelID.isEmpty ? nil : AssistantCatalog.chatModel(id: meetingNotesModelID)
    }

    /// Language for meetings; nil means auto-detect.
    var meetingLanguageCode: String? {
        switch meetingLanguage {
        case "same": return languageCode
        case "auto": return nil
        default: return meetingLanguage
        }
    }

    /// Hours, clamped to something sensible.
    var meetingMaxSeconds: Double {
        Double(min(12, max(1, meetingMaxHours))) * 3600
    }

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

/// How readily the meeting clean-up treats sound as speech.
enum SpeechSensitivity: String, CaseIterable, Identifiable {
    case low, normal, high

    var id: String { rawValue }

    var title: String {
        switch self {
        case .low: return "Low (noisy room)"
        case .normal: return "Normal"
        case .high: return "High (quiet voices)"
        }
    }

    /// Silero VAD probability above which audio counts as speech.
    var threshold: Float {
        switch self {
        case .low: return 0.85
        case .normal: return 0.7
        case .high: return 0.5
        }
    }
}

/// How much the meeting notes say.
enum NotesDetail: String, CaseIterable, Identifiable {
    case brief, standard, detailed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .brief: return "Brief"
        case .standard: return "Standard"
        case .detailed: return "Detailed"
        }
    }

    /// What the summary should look like, for the AI prompt.
    var summaryLength: String {
        switch self {
        case .brief: return "2 to 3 sentences"
        case .standard: return "3 to 6 sentences"
        case .detailed: return "2 or 3 short paragraphs covering each topic discussed"
        }
    }

    var keyPointsHint: String {
        switch self {
        case .brief: return "at most 4"
        case .standard: return "up to 8"
        case .detailed: return "as many as needed"
        }
    }

    var maxTokens: Int {
        switch self {
        case .brief: return 700
        case .standard: return 1_200
        case .detailed: return 2_000
        }
    }
}

/// What to do with a Mac command recognised by meaning (Settings › Search & memory).
enum CommandMatching: String, CaseIterable, Identifiable {
    case off, suggest, run

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "Off"
        case .suggest: return "Suggest only"
        case .run: return "Run safe commands"
        }
    }

    var detail: String {
        switch self {
        case .off: return "Only the usual phrasings work; anything else goes to the AI model."
        case .suggest: return "Shows “Did you mean…” with the closest commands; nothing runs until you click one."
        case .run: return "Runs the closest command when it's a clear match. Risky ones (lock, sleep, quit, empty Trash…) always ask first."
        }
    }
}
