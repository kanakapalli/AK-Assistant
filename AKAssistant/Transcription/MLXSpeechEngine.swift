// Compiled only when the mlx-audio-swift package (product MLXAudioSTT) is added to the project.
#if canImport(MLXAudioSTT)
import Foundation
import os
import MLX
import MLXAudioSTT

// Speech-to-text with Apple's MLX framework on the GPU, via mlx-audio-swift
// (https://github.com/Blaizzy/mlx-audio-swift). These are actors so the heavy MLX work runs off the
// main thread, and one model never runs two transcriptions at once.

enum MLXSpeechError: LocalizedError {
    case wrongModel(String)
    var errorDescription: String? {
        switch self { case .wrongModel(let repo): return "\(repo) isn't a model mlx-audio-swift can stream" }
    }
}

/// Parakeet or Whisper on MLX: transcribes a whole recording at a time.
actor MLXSpeechEngine: TranscriptionEngine {
    private let model: any STTGenerationModel
    private let family: String

    init(spec: MLXSpeechSpec) async throws {
        let log = Logger(subsystem: "com.natfirst.akassistant", category: "Transcription")
        let started = Date()
        model = try await STT.loadModel(modelRepo: spec.repo, modelType: spec.family)
        family = spec.family
        log.info("MLX \(spec.family, privacy: .public): model ready in \(Date().timeIntervalSince(started), format: .fixed(precision: 1))s")
    }

    /// Downloads the weights into the Hugging Face cache (loading once also checks them).
    static func download(_ spec: MLXSpeechSpec) async throws {
        _ = try await STT.loadModel(modelRepo: spec.repo, modelType: spec.family)
    }

    func transcribe(_ samples: [Float], language: String?) async throws -> String {
        let audio = MLXArray(samples)
        // Whisper takes a language hint; Parakeet detects the language itself.
        let parameters = family == "whisper"
            ? STTGenerateParameters(language: language)
            : model.defaultGenerationParameters
        let output = model.generate(audio: audio, generationParameters: parameters)
        return output.text
    }
}

/// Nemotron Streaming on MLX: keeps its state between pieces of audio, so text arrives while you talk.
actor MLXNemotronStreamingEngine: StreamingTranscriptionEngine {
    private let model: NemotronASRModel
    private var session: NemotronASRStreamSession?

    init(spec: MLXSpeechSpec) async throws {
        let log = Logger(subsystem: "com.natfirst.akassistant", category: "Transcription")
        let started = Date()
        guard let loaded = try await STT.loadModel(modelRepo: spec.repo, modelType: spec.family) as? NemotronASRModel else {
            throw MLXSpeechError.wrongModel(spec.repo)
        }
        model = loaded
        log.info("MLX Nemotron Streaming: model ready in \(Date().timeIntervalSince(started), format: .fixed(precision: 1))s")
    }

    func beginStream() {
        // 560 ms steps: the same latency tier as the Core ML version.
        session = model.makeStreamSession(language: nil, chunkMs: 560)
    }

    func feed(_ samples: [Float]) -> String {
        if session == nil { beginStream() }
        guard let session else { return "" }
        if !samples.isEmpty { _ = session.step(samples) }
        return session.text
    }

    func finishStream() -> String {
        guard let session else { return "" }
        _ = session.finish()
        self.session = nil
        return session.text
    }

    func transcribe(_ samples: [Float], language: String?) async throws -> String {
        beginStream()
        _ = feed(samples)
        return finishStream()
    }
}

#endif
