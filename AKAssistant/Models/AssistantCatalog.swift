import Foundation

/// A chat model from Hugging Face, run locally with Apple's MLX framework.
struct ChatModel: Identifiable, Hashable {
    let id: String
    let name: String
    /// Hugging Face repo, e.g. "mlx-community/Qwen3-4B-4bit".
    let repo: String
    let sizeLabel: String
    let summary: String
    let speed: Int      // 1 (slowest) ... 5 (fastest), for the UI
    let quality: Int    // 1 ... 5
    /// Tokens that end a reply for this model family.
    let extraEOSTokens: Set<String>
    /// Qwen3 "thinks" out loud before answering unless this is turned off.
    let disableThinking: Bool

    var huggingFaceURL: URL { URL(string: "https://huggingface.co/\(repo)")! }
}

/// Which Qwen3-TTS model speaks the answers (via Argmax TTSKit, Core ML).
struct VoiceModel: Identifiable, Hashable {
    let id: String          // matches TTSKit's TTSModelVariant raw value: "0.6b" / "1.7b"
    let name: String
    let sizeLabel: String
    let summary: String
}

/// How the assistant gives its answer back.
enum ReplyStyle: String, CaseIterable, Identifiable, Codable {
    case panelAndVoice
    case panelOnly
    case voiceOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .panelAndVoice: return "Show and speak"
        case .panelOnly: return "Show only"
        case .voiceOnly: return "Speak only"
        }
    }

    var detail: String {
        switch self {
        case .panelAndVoice: return "A floating answer panel appears and the answer is read aloud."
        case .panelOnly: return "The answer appears in a floating panel. Nothing is spoken."
        case .voiceOnly: return "The answer is read aloud. It's still saved in History."
        }
    }

    var speaks: Bool { self != .panelOnly }
    var shows: Bool { self != .voiceOnly }
}

enum AssistantCatalog {
    static let chatModels: [ChatModel] = [
        ChatModel(
            id: "qwen3-4b",
            name: "Qwen3 4B",
            repo: "mlx-community/Qwen3-4B-4bit",
            sizeLabel: "2.3 GB",
            summary: "Smart, fast answers in many languages. Recommended.",
            speed: 4, quality: 4,
            extraEOSTokens: ["<|im_end|>"],
            disableThinking: true
        ),
        ChatModel(
            id: "gemma4-e4b",
            name: "Gemma 4 E4B",
            repo: "mlx-community/gemma-4-e4b-it-4bit",
            sizeLabel: "5.2 GB",
            summary: "Google's best small model here. Highest quality; needs 16 GB of memory.",
            speed: 3, quality: 5,
            extraEOSTokens: ["<turn|>"],
            disableThinking: false
        ),
        ChatModel(
            id: "gemma4-e2b",
            name: "Gemma 4 E2B",
            repo: "mlx-community/gemma-4-e2b-it-4bit",
            sizeLabel: "3.6 GB",
            summary: "Lighter Gemma 4; good balance of quality and speed.",
            speed: 4, quality: 4,
            extraEOSTokens: ["<turn|>"],
            disableThinking: false
        ),
        ChatModel(
            id: "llama3.2-3b",
            name: "Llama 3.2 3B",
            repo: "mlx-community/Llama-3.2-3B-Instruct-4bit",
            sizeLabel: "1.8 GB",
            summary: "Meta's compact assistant model; quick everyday answers.",
            speed: 4, quality: 3,
            extraEOSTokens: ["<|eot_id|>"],
            disableThinking: false
        ),
        ChatModel(
            id: "qwen3-1.7b",
            name: "Qwen3 1.7B",
            repo: "mlx-community/Qwen3-1.7B-4bit",
            sizeLabel: "1.0 GB",
            summary: "Smallest and fastest. Best for 8 GB Macs.",
            speed: 5, quality: 2,
            extraEOSTokens: ["<|im_end|>"],
            disableThinking: true
        ),
    ]

    static let voiceModels: [VoiceModel] = [
        VoiceModel(id: "0.6b", name: "Qwen3 TTS 0.6B", sizeLabel: "~1 GB",
                   summary: "Natural voice with low delay. Recommended."),
        VoiceModel(id: "1.7b", name: "Qwen3 TTS 1.7B", sizeLabel: "~2.2 GB",
                   summary: "Richer, more expressive voice; a little slower."),
    ]

    /// Built-in Qwen3-TTS speakers (TTSKit's `Qwen3Speaker` raw values).
    static let voices: [(id: String, name: String)] = [
        ("ryan", "Ryan"), ("aiden", "Aiden"), ("eric", "Eric"), ("dylan", "Dylan"),
        ("serena", "Serena"), ("vivian", "Vivian"), ("ono-anna", "Ono Anna"),
        ("sohee", "Sohee"), ("uncle-fu", "Uncle Fu"),
    ]

    static var defaultChatModel: ChatModel { chatModels[0] }
    static var defaultVoiceModel: VoiceModel { voiceModels[0] }

    static func chatModel(id: String) -> ChatModel? { chatModels.first { $0.id == id } }
    static func voiceModel(id: String) -> VoiceModel? { voiceModels.first { $0.id == id } }
}
