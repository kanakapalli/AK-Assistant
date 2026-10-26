import Foundation

enum EngineKind: String, Codable {
    case whisperKit   // argmaxinc/whisperkit-coreml
    case parakeet     // FluidInference Parakeet models via FluidAudio (Ultra, v2, Redux)
    case nemotronStreaming   // NVIDIA Nemotron Speech Streaming via FluidAudio: transcribes while you talk
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
    /// Added by the user (see CustomModels.swift) rather than built in.
    var isCustom = false
    /// Where this model can run, in order of preference (the first is the default).
    var runtimes: [ModelRuntime] = [.gpu, .neuralEngine]
    /// The MLX version, if this model offers the MLX runtime.
    var mlx: MLXSpeechSpec? = nil

    /// Streams: text appears while you talk and is ready the moment you let go. Other models re-read
    /// the recording for the live preview and transcribe it once more at the end.
    var supportsStreaming: Bool { engine == .nemotronStreaming }

    var huggingFaceURL: URL {
        URL(string: "https://huggingface.co/\(repo)")!
    }
}

enum ModelCatalog {
    /// Built-in models plus any the user added.
    @MainActor static var all: [SpeechModel] { builtIn + CustomModelStore.shared.speechModels }

    // Chosen from benchmarks (Oct 2026). For typing, NVIDIA's Parakeet models beat Whisper on both speed
    // and accuracy: ~2.1% word error rate on LibriSpeech test-clean vs ~5% for Whisper, 100x+ faster than
    // real time on the Neural Engine, built-in punctuation and capitals, and no made-up words in silence.
    // Whisper stays for Hindi and the other languages Parakeet doesn't cover.
    static let builtIn: [SpeechModel] = [
        SpeechModel(
            id: "parakeet-ultra",
            name: "Parakeet Ultra",
            engine: .parakeet,
            variant: "ultra",
            repo: "FluidInference/parakeet-ultra-coreml",
            sizeLabel: "~650 MB",
            languages: "English + 24 European languages",
            summary: "Fastest and most accurate for typing. Adds punctuation and capitals, runs on the Neural Engine. Recommended.",
            speed: 5,
            accuracy: 5,
            runtimes: [.gpu, .neuralEngine]   // no MLX build of Ultra exists yet
        ),
        SpeechModel(
            id: "parakeet-tdt-0.6b-v2",
            name: "Parakeet v2 (English)",
            engine: .parakeet,
            variant: "v2",
            repo: "FluidInference/parakeet-tdt-0.6b-v2-coreml",
            sizeLabel: "~600 MB",
            languages: "English only",
            summary: "English-only version, on par with Ultra for English. Try it if you only ever dictate in English.",
            speed: 5,
            accuracy: 5,
            runtimes: [.gpu, .neuralEngine, .mlx],
            mlx: MLXSpeechSpec(repo: "mlx-community/parakeet-tdt-0.6b-v2", family: "parakeet", sizeLabel: "~1.2 GB")
        ),
        SpeechModel(
            id: "nemotron-streaming-en",
            name: "Nemotron Streaming (English)",
            engine: .nemotronStreaming,
            variant: "560ms",
            repo: "FluidInference/nemotron-speech-streaming-en-0.6b-coreml",
            sizeLabel: "~600 MB",
            languages: "English only",
            summary: "Streams: words appear about half a second after you say them, and the text is ready the moment you let go. Similar accuracy to Parakeet.",
            speed: 5,
            accuracy: 5,
            // Core ML on the GPU runs this int8 model ~10x slower, so only the Neural Engine and MLX are offered.
            runtimes: [.neuralEngine, .mlx],
            mlx: MLXSpeechSpec(repo: "animaslabs/nemotron-speech-streaming-en-0.6b-mlx-8bit", family: "nemotron", sizeLabel: "~700 MB")
        ),
        SpeechModel(
            id: "parakeet-redux",
            name: "Parakeet Redux (small)",
            engine: .parakeet,
            variant: "redux",
            repo: "FluidInference/parakeet-redux-coreml",
            sizeLabel: "~220 MB",
            languages: "English + 24 European languages",
            summary: "Smallest download, for 8 GB Macs or slow internet. Slightly less accurate than Ultra.",
            speed: 4,
            accuracy: 4,
            runtimes: [.gpu, .neuralEngine]
        ),
        SpeechModel(
            id: "whisper-large-v3-turbo",
            name: "Whisper Large v3 Turbo",
            engine: .whisperKit,
            variant: "openai_whisper-large-v3-v20240930_turbo_632MB",
            repo: "argmaxinc/whisperkit-coreml",
            sizeLabel: "632 MB",
            languages: "99 languages",
            summary: "For Hindi and other languages Parakeet doesn't cover. Slower than Parakeet.",
            speed: 2,
            accuracy: 4,
            runtimes: [.gpu, .neuralEngine, .mlx],
            mlx: MLXSpeechSpec(repo: "mlx-community/whisper-large-v3-turbo", family: "whisper", sizeLabel: "~1.6 GB")
        ),
    ]

    /// Models offered by older versions of the app. Their files are removed on launch and anyone
    /// using one is moved to the new default.
    static let retiredIDs: Set<String> = [
        "parakeet-tdt-0.6b-v3", "distil-whisper-large-v3-turbo", "whisper-small", "whisper-base-en",
    ]

    static var defaultModel: SpeechModel { builtIn[0] }

    @MainActor static func model(id: String) -> SpeechModel? {
        all.first { $0.id == id }
    }
}
