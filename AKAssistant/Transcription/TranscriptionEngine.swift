import Foundation
import CoreML
import os
import WhisperKit
import FluidAudio
import AVFoundation

/// Anything that turns 16 kHz mono samples into text. New backends (or an LLM cleanup step) plug in here.
protocol TranscriptionEngine: AnyObject {
    func transcribe(_ samples: [Float], language: String?) async throws -> String
}

/// An engine that transcribes while audio is still arriving, instead of after the recording ends.
protocol StreamingTranscriptionEngine: TranscriptionEngine {
    /// Starts a new utterance (clears anything from the previous one).
    func beginStream() async
    /// Adds newly recorded 16 kHz audio and returns the transcript so far.
    func feed(_ samples: [Float]) async throws -> String
    /// Processes what's left and returns the final transcript.
    func finishStream() async throws -> String
}

enum TranscriptionError: LocalizedError {
    case modelNotDownloaded(String)

    var errorDescription: String? {
        switch self {
        case .modelNotDownloaded(let name): return "\(name) is not downloaded"
        }
    }
}

// MARK: - WhisperKit (Whisper models)

final class WhisperKitEngine: TranscriptionEngine {
    private let pipe: WhisperKit

    /// For the log: where Core ML was asked to run the model.
    static func describe(_ units: MLComputeUnits) -> String {
        switch units {
        case .cpuOnly: return "CPU"
        case .cpuAndNeuralEngine: return "Neural Engine"
        default: return "GPU"
        }
    }

    /// - Parameter computeUnits: `.cpuAndGPU` loads in seconds and is fast on Apple Silicon.
    ///   `.cpuAndNeuralEngine` uses less power, but the first load compiles ("specializes") the model for this
    ///   Mac, which can take many minutes for the large models. macOS caches that result, so later loads are quick.
    ///   `.cpuOnly` keeps the GPU and Neural Engine free and is the slowest.
    init(modelFolder: URL, computeUnits units: MLComputeUnits) async throws {
        let compute = ModelComputeOptions(
            melCompute: units == .cpuOnly ? .cpuOnly : .cpuAndGPU,
            audioEncoderCompute: units,
            textDecoderCompute: units
        )
        // prewarm is off: it runs the compile as a separate pass before loading, which adds time on first run.
        let config = WhisperKitConfig(
            modelFolder: modelFolder.path,
            computeOptions: compute,
            verbose: false,
            logLevel: .error,       // debug logging prints for every decoded token and slows transcription
            prewarm: false,
            load: true,
            download: false
        )
        let log = Logger(subsystem: "com.natfirst.akassistant", category: "Transcription")
        log.info("WhisperKit: loading model on \(Self.describe(units), privacy: .public) from \(modelFolder.path, privacy: .public)")
        let started = Date()
        pipe = try await WhisperKit(config)
        log.info("WhisperKit: model ready in \(Date().timeIntervalSince(started), format: .fixed(precision: 1))s")
    }

    func transcribe(_ samples: [Float], language: String?) async throws -> String {
        let options = DecodingOptions(
            task: .transcribe,
            language: language,
            temperature: 0,
            temperatureFallbackCount: 2,   // default 5: re-decodes up to 5 more times on unclear audio
            usePrefillPrompt: language != nil,
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            withoutTimestamps: true
        )
        let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)
        return results.map(\.text).joined(separator: " ")
    }
}

// MARK: - Parakeet via FluidAudio

final class ParakeetEngine: TranscriptionEngine {
    private let manager: AsrManager
    private let version: AsrModelVersion

    /// Which FluidAudio model a catalog entry means ("ultra", "v2", "redux", "v3").
    static func version(for model: SpeechModel) -> AsrModelVersion {
        switch model.variant {
        case "v2": return .v2
        case "redux": return .redux
        case "v3": return .v3
        default: return .ultra
        }
    }

    /// - Parameter computeUnits: where every part of the model runs (GPU, Neural Engine or CPU).
    init(version: AsrModelVersion, computeUnits units: MLComputeUnits) async throws {
        self.version = version
        let log = Logger(subsystem: "com.natfirst.akassistant", category: "Transcription")
        let started = Date()
        let configuration = MLModelConfiguration()
        configuration.computeUnits = units
        let folder = AsrModels.defaultCacheDirectory(for: version)
        // Load what's already downloaded; only go to the network if the files are missing.
        let models = AsrModels.modelsExist(at: folder, version: version)
            ? try await AsrModels.load(from: folder, configuration: configuration, version: version, encoderComputeUnits: units)
            : try await AsrModels.downloadAndLoad(configuration: configuration, version: version, encoderComputeUnits: units)
        log.info("Parakeet: loading on \(WhisperKitEngine.describe(units), privacy: .public)")
        manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        log.info("Parakeet: model ready in \(Date().timeIntervalSince(started), format: .fixed(precision: 1))s")
    }

    func transcribe(_ samples: [Float], language: String?) async throws -> String {
        // Parakeet wants at least ~1 s of audio; pad short clips with silence.
        var audio = samples
        let minimum = Int(AudioRecorder.sampleRate)
        if audio.count < minimum {
            audio.append(contentsOf: [Float](repeating: 0, count: minimum - audio.count))
        }
        var decoderState = try TdtDecoderState(decoderLayers: version.decoderLayers)
        let result = try await manager.transcribe(audio, decoderState: &decoderState)
        return result.text
    }
}

// MARK: - Nemotron Streaming via FluidAudio

/// NVIDIA's Nemotron Speech Streaming (English, 0.6B). It works through the audio in 0.56 s steps as you
/// talk, keeping its state between steps, so nothing is re-read and the final text is ready right away.
final class NemotronStreamingEngine: StreamingTranscriptionEngine {
    static let chunkSize: NemotronChunkSize = .ms560   // lowest-latency tier; same accuracy as the larger ones

    /// Where FluidAudio keeps the model (Application Support/FluidAudio/Models/...).
    static var modelFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models", isDirectory: true)
            .appendingPathComponent(chunkSize.repo.folderName, isDirectory: true)
    }

    private let manager: StreamingNemotronAsrManager
    private let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: AudioRecorder.sampleRate, channels: 1, interleaved: false
    )!

    /// Downloads the model (if needed) and loads it.
    /// It always runs on the Neural Engine: its int8 encoder is built for it, and FluidAudio measured it
    /// about 10x slower on the GPU. This is the one exception to the "everything on the GPU" setting.
    init() async throws {
        let log = Logger(subsystem: "com.natfirst.akassistant", category: "Transcription")
        let started = Date()
        manager = StreamingNemotronAsrManager(requestedChunkSize: Self.chunkSize)
        try await manager.loadModels(to: nil, configuration: nil, progressHandler: nil)
        log.info("Nemotron Streaming: model ready in \(Date().timeIntervalSince(started), format: .fixed(precision: 1))s")
    }

    /// Downloads the model files without keeping the model in memory.
    static func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        let manager = StreamingNemotronAsrManager(requestedChunkSize: chunkSize)
        try await manager.loadModels(to: nil, configuration: nil, progressHandler: { progress($0.fractionCompleted) })
        await manager.cleanup()
    }

    func beginStream() async {
        await manager.reset()
    }

    func feed(_ samples: [Float]) async throws -> String {
        if !samples.isEmpty, let buffer = makeBuffer(samples) {
            _ = try await manager.process(audioBuffer: buffer)
        }
        return await manager.getPartialTranscript()
    }

    func finishStream() async throws -> String {
        try await manager.finish()
    }

    /// Whole-recording transcription (used for warm-up and as a fallback).
    func transcribe(_ samples: [Float], language: String?) async throws -> String {
        await beginStream()
        _ = try await feed(samples)
        return try await finishStream()
    }

    private func makeBuffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        return buffer
    }
}
