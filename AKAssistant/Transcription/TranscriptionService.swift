import Foundation

/// Keeps the selected model loaded between dictations and unloads it after a period of inactivity.
@MainActor
final class TranscriptionService {
    private var engine: TranscriptionEngine?
    private var loadedModelID: String?
    private var loadingTask: Task<TranscriptionEngine, Error>?
    private var loadingModelID: String?
    private var idleTask: Task<Void, Never>?

    /// Unload after this long without a dictation, to free memory. Reloading means another cold
    /// start (load + GPU kernel compile), so keep it loaded for a long time.
    var idleUnloadInterval: TimeInterval = 4 * 60 * 60

    func prepare(model: SpeechModel, modelManager: ModelManager) async throws {
        _ = try await engine(for: model, modelManager: modelManager)
    }

    func transcribe(_ samples: [Float], model: SpeechModel, language: String?, modelManager: ModelManager) async throws -> String {
        let engine = try await engine(for: model, modelManager: modelManager)
        let text = try await engine.transcribe(samples, language: language)
        scheduleIdleUnload()
        return text
    }

    /// The selected model's engine if it can stream (loads it if needed), otherwise nil.
    func streamingEngine(for model: SpeechModel, modelManager: ModelManager) async throws -> StreamingTranscriptionEngine? {
        guard model.supportsStreaming else { return nil }
        let engine = try await engine(for: model, modelManager: modelManager) as? StreamingTranscriptionEngine
        scheduleIdleUnload()
        return engine
    }

    func unload() {
        engine = nil
        loadedModelID = nil
        loadingTask?.cancel()
        loadingTask = nil
        loadingModelID = nil
        idleTask?.cancel()
    }

    // MARK: - Private

    private func engine(for model: SpeechModel, modelManager: ModelManager) async throws -> TranscriptionEngine {
        // A model loaded for a different runtime (picked in Settings) counts as a different engine.
        let runtime = ModelRuntimeStore.shared.runtime(for: model)
        let key = model.id + "@" + runtime.rawValue
        if let engine, loadedModelID == key {
            return engine
        }
        // Reuse an in-flight load (the recorder starts loading while you talk).
        if let loadingTask, loadingModelID == key {
            return try await loadingTask.value
        }

        guard modelManager.isDownloaded(model) else {
            throw TranscriptionError.modelNotDownloaded(model.name)
        }

        let folder = modelManager.localFolder(for: model)
        let task = Task<TranscriptionEngine, Error> {
            let engine = try await Self.makeEngine(model: model, runtime: runtime, folder: folder)
            // Warm-up: run one second of silence through the model right after loading. The first
            // real transcription otherwise pays for compiling the GPU / Neural Engine kernels, which
            // can take seconds. (The faster wisperflow-local app does the same.)
            let started = Date()
            _ = try? await engine.transcribe([Float](repeating: 0, count: Int(AudioRecorder.sampleRate)), language: "en")
            NSLog("Duck Keyboard: speech model warmed up in %.2fs", Date().timeIntervalSince(started))
            return engine
        }
        loadingTask = task
        loadingModelID = key

        do {
            let loaded = try await task.value
            engine = loaded
            loadedModelID = key
            loadingTask = nil
            loadingModelID = nil
            scheduleIdleUnload()
            return loaded
        } catch {
            loadingTask = nil
            loadingModelID = nil
            throw error
        }
    }

    private static func makeEngine(model: SpeechModel, runtime: ModelRuntime, folder: URL?) async throws -> TranscriptionEngine {
        #if canImport(MLXAudioSTT)
        if runtime == .mlx {
            guard let spec = model.mlx else { throw TranscriptionError.modelNotDownloaded(model.name) }
            if model.supportsStreaming { return try await MLXNemotronStreamingEngine(spec: spec) }
            return try await MLXSpeechEngine(spec: spec)
        }
        #endif
        switch model.engine {
        case .whisperKit:
            guard let folder else { throw TranscriptionError.modelNotDownloaded(model.name) }
            return try await WhisperKitEngine(modelFolder: folder, computeUnits: runtime.computeUnits)
        case .nemotronStreaming:
            return try await NemotronStreamingEngine()
        case .parakeet:
            return try await ParakeetEngine(version: ParakeetEngine.version(for: model), computeUnits: runtime.computeUnits)
        }
    }

    private func scheduleIdleUnload() {
        idleTask?.cancel()
        idleTask = Task { [weak self, idleUnloadInterval] in
            try? await Task.sleep(for: .seconds(idleUnloadInterval))
            guard !Task.isCancelled else { return }
            self?.unload()
        }
    }
}
