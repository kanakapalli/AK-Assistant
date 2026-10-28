import Foundation

/// The kinds of model the app runs. Each feature needs one kind.
enum ModelKind: String, CaseIterable, Identifiable {
    case speech, chat, voice, search

    var id: String { rawValue }

    var title: String {
        switch self {
        case .speech: return "Speech to text"
        case .chat: return "AI"
        case .voice: return "Voice"
        case .search: return "Search"
        }
    }

    /// "Speech model", "AI model"… for rows that name the model a feature uses.
    var modelTitle: String {
        switch self {
        case .speech: return "Speech model"
        case .chat: return "AI model"
        case .voice: return "Voice model"
        case .search: return "Search model"
        }
    }

    var symbol: String {
        switch self {
        case .speech: return "waveform"
        case .chat: return "sparkles"
        case .voice: return "speaker.wave.2.fill"
        case .search: return "magnifyingglass"
        }
    }

    /// One line under the library section for this kind.
    var libraryCaption: String {
        switch self {
        case .speech: return "Core ML models can run on the GPU (fast to load), the Neural Engine (least power) or the CPU (slowest, keeps the others free). MLX is a separate, GPU-only download."
        case .chat: return "Run with Apple's MLX framework, which uses the GPU. Bigger models answer better but are slower and use more memory. Only one AI model is in memory at a time."
        case .voice: return "Qwen3 TTS runs on the Neural Engine only (on the GPU its maths overflows)."
        case .search: return "Built in. Turned on and off with Smart search & memory in Settings › AI Assistant."
        }
    }
}

/// Everything in the app that uses a model. Settings › Models assigns a model to each one.
enum ModelFeature: String, CaseIterable, Identifiable {
    case dictation, assistant, writingTools, meetingTranscript, meetingNotes, readAloud, smartSearch

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dictation: return "Dictation & AI key"
        case .assistant: return "AI answers & commands"
        case .writingTools: return "Writing tools"
        case .meetingTranscript: return "Meeting clean-up"
        case .meetingNotes: return "Meeting notes"
        case .readAloud: return "Read answers aloud"
        case .smartSearch: return "Smart search & memory"
        }
    }

    /// Short name for "Used by" chips.
    var shortTitle: String {
        switch self {
        case .dictation: return "Dictation"
        case .assistant: return "AI answers"
        case .writingTools: return "Writing tools"
        case .meetingTranscript: return "Meeting clean-up"
        case .meetingNotes: return "Meeting notes"
        case .readAloud: return "Read aloud"
        case .smartSearch: return "Smart search"
        }
    }

    var detail: String {
        switch self {
        case .dictation: return "Turns what you say into text, for dictation, questions to the AI and live meeting transcripts."
        case .assistant: return "Answers questions and understands Mac commands phrased any way."
        case .writingTools: return "Fixes grammar and rewrites text with your shortcuts."
        case .meetingTranscript: return "Redoes the transcript after a meeting; a larger model is more accurate on noisy audio."
        case .meetingNotes: return "Writes the summary, key points and to-dos when a meeting ends."
        case .readAloud: return "Speaks the AI's answers."
        case .smartSearch: return "Finds meetings and history by meaning and matches commands in any language."
        }
    }

    var symbol: String {
        switch self {
        case .dictation: return "mic.fill"
        case .assistant: return "sparkles"
        case .writingTools: return "text.badge.checkmark"
        case .meetingTranscript: return "person.2.wave.2.fill"
        case .meetingNotes: return "list.bullet.clipboard"
        case .readAloud: return "speaker.wave.2.fill"
        case .smartSearch: return "magnifyingglass"
        }
    }

    var kind: ModelKind {
        switch self {
        case .dictation, .meetingTranscript: return .speech
        case .assistant, .writingTools, .meetingNotes: return .chat
        case .readAloud: return .voice
        case .smartSearch: return .search
        }
    }

    /// The Settings page with this feature's other options.
    var settingsTab: SettingsTab {
        switch self {
        case .dictation: return .dictation
        case .assistant, .readAloud, .smartSearch: return .assistant
        case .writingTools: return .grammar
        case .meetingTranscript, .meetingNotes: return .meetings
        }
    }

    /// Features that can simply use another feature's model ("Same as …").
    var follows: ModelFeature? {
        switch self {
        case .meetingTranscript: return .dictation
        case .writingTools, .meetingNotes: return .assistant
        default: return nil
        }
    }
}

// MARK: - Reading and changing assignments

@MainActor
extension Preferences {
    /// The model id picked for a feature. "" means it follows another feature (see `ModelFeature.follows`).
    func assignedModelID(for feature: ModelFeature) -> String {
        switch feature {
        case .dictation: return selectedModelID
        case .meetingTranscript: return meetingFinalModelID
        case .assistant: return chatModelID
        case .writingTools: return writingModelID
        case .meetingNotes: return meetingNotesModelID
        case .readAloud: return voiceModelID
        case .smartSearch: return GemmaEmbedder.repo
        }
    }

    func assign(_ id: String, to feature: ModelFeature) {
        switch feature {
        case .dictation: selectedModelID = id
        case .meetingTranscript: meetingFinalModelID = id
        case .assistant: chatModelID = id
        case .writingTools: writingModelID = id
        case .meetingNotes: meetingNotesModelID = id
        case .readAloud: voiceModelID = id
        case .smartSearch: break   // one built-in model
        }
    }

    /// The model id the feature ends up with, after following "Same as …".
    func effectiveModelID(for feature: ModelFeature) -> String {
        let id = assignedModelID(for: feature)
        if id.isEmpty, let parent = feature.follows { return effectiveModelID(for: parent) }
        return id
    }

    /// The feature is switched on (its model is only used when it is).
    func isActive(_ feature: ModelFeature) -> Bool {
        switch feature {
        case .dictation: return true
        case .assistant: return assistantEnabled
        case .writingTools: return grammarFixEnabled
        case .meetingTranscript: return meetingCleanupPass
        case .meetingNotes: return true   // notes can always be written from a meeting's ⋯ menu
        case .readAloud: return assistantEnabled && replyStyle.speaks
        case .smartSearch: return memoryEnabled
        }
    }

    /// The features (of one kind) that use a model, after following "Same as …".
    func features(using id: String, kind: ModelKind) -> [ModelFeature] {
        ModelFeature.allCases.filter { $0.kind == kind && effectiveModelID(for: $0) == id }
    }

    /// After a custom model is removed: features that picked it go back to their default.
    func unassign(_ id: String) {
        for feature in ModelFeature.allCases where assignedModelID(for: feature) == id {
            switch feature {
            case .dictation: selectedModelID = ModelCatalog.defaultModel.id
            case .assistant: chatModelID = AssistantCatalog.defaultChatModel.id
            case .readAloud: voiceModelID = AssistantCatalog.defaultVoiceModel.id
            case .meetingTranscript, .writingTools, .meetingNotes: assign("", to: feature)
            case .smartSearch: break
            }
        }
    }
}
