import Foundation

enum EngineKind: String, Codable {
    case whisperKit   // argmaxinc/whisperkit-coreml
    case parakeet     // FluidInference/parakeet-tdt-0.6b-v3-coreml via FluidAudio
}

/// One downloadable speech-to-text model from Hugging Face.
struct SpeechModel: Identifiable, Hashable {
    let id: String
    let name: String
    let engine: EngineKind
    /// WhisperKit variant folder name inside the repo (unused for Parakeet).
    let variant: String
    let repo: String
    let sizeLabel: String
    let languages: String
    let summary: String
    let speed: Int      // 1 (slowest) ... 5 (fastest), for the UI
    let accuracy: Int   // 1 ... 5

    var huggingFaceURL: URL {
        URL(string: "https://huggingface.co/\(repo)")!
    }
}

enum ModelCatalog {
    static let all: [SpeechModel] = [
        SpeechModel(
            id: "whisper-large-v3-turbo",
            name: "Whisper Large v3 Turbo",
            engine: .whisperKit,
            variant: "openai_whisper-large-v3-v20240930_turbo_632MB",
            repo: "argmaxinc/whisperkit-coreml",
            sizeLabel: "632 MB",
            languages: "99 languages",
            summary: "Best all-round accuracy, including Indian English and Hindi. Recommended.",
            speed: 3,
            accuracy: 5
        ),
        SpeechModel(
            id: "parakeet-tdt-0.6b-v3",
            name: "Parakeet TDT 0.6B v3",
            engine: .parakeet,
            variant: "",
            repo: "FluidInference/parakeet-tdt-0.6b-v3-coreml",
            sizeLabel: "~600 MB",
            languages: "25 European languages + Japanese",
            summary: "Fastest option with built-in punctuation and casing. No Indian languages.",
            speed: 5,
            accuracy: 4
        ),
        SpeechModel(
            id: "distil-whisper-large-v3-turbo",
            name: "Distil-Whisper Large v3 Turbo",
            engine: .whisperKit,
            variant: "distil-whisper_distil-large-v3_turbo_600MB",
            repo: "argmaxinc/whisperkit-coreml",
            sizeLabel: "600 MB",
            languages: "English",
            summary: "English only, lower latency than full Turbo.",
            speed: 4,
            accuracy: 4
        ),
        SpeechModel(
            id: "whisper-small",
            name: "Whisper Small",
            engine: .whisperKit,
            variant: "openai_whisper-small_216MB",
            repo: "argmaxinc/whisperkit-coreml",
            sizeLabel: "216 MB",
            languages: "99 languages",
            summary: "Good for 8 GB Macs and quick setup; multilingual.",
            speed: 4,
            accuracy: 3
        ),
        SpeechModel(
            id: "whisper-base-en",
            name: "Whisper Base (English)",
            engine: .whisperKit,
            variant: "openai_whisper-base.en",
            repo: "argmaxinc/whisperkit-coreml",
            sizeLabel: "~150 MB",
            languages: "English",
            summary: "Smallest and quickest to download; low-power fallback.",
            speed: 5,
            accuracy: 2
        ),
    ]

    static var defaultModel: SpeechModel { all[0] }

    static func model(id: String) -> SpeechModel? {
        all.first { $0.id == id }
    }
}
