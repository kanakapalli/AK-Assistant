import Foundation
import os
import TTSKit

/// Speaks answers aloud with a local Qwen3-TTS model (Argmax TTSKit, Core ML, from Hugging Face).
///
/// Speed notes:
/// - Answers are spoken while the AI is still writing them: AppState feeds finished sentences in
///   with `enqueue(_:)`, and the next sentence is generated while the current one is playing.
/// - One audio session covers the whole answer, so there are no gaps between sentences.
/// - The voice's prompt cache (the fixed speaker/language prefix) is built once and saved to disk,
///   which removes most of the start-up work for every sentence.
@MainActor
final class SpeechService {
    private var tts: TTSKit?
    private var loadedVariant: String?
    private var loadingTask: Task<TTSKit, Error>?
    private var loadingVariant: String?
    private var cachedVoiceKey: String?

    private var speakTask: Task<Void, Never>?
    private var input: AsyncStream<String>.Continuation?
    private var stopFlag = StopFlag()
    private let log = Logger(subsystem: "com.natfirst.akassistant", category: "Speech")

    /// Called when an answer finishes being spoken (not when it's stopped early).
    var onFinished: (@MainActor () -> Void)?

    /// Downloads a voice model and returns its local folder.
    static func download(variant id: String, to base: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let variant = TTSModelVariant(rawValue: id) ?? .qwen3TTS_0_6b
        return try await TTSKit.download(
            variant: variant,
            downloadBase: base,
            progressCallback: { p in progress(p.fractionCompleted) }
        )
    }

    // MARK: - Loading

    /// Loads the voice model (once) and warms the prompt cache for this speaker and language,
    /// so the first sentence starts playing quickly.
    func prepare(variant id: String, folder: URL, voice: String, languageCode: String?) async throws {
        let tts = try await load(variant: id, folder: folder)
        let speaker = Qwen3Speaker(rawValue: voice) ?? .ryan
        let language = Self.language(for: languageCode)
        let key = "\(id)|\(speaker.rawValue)|\(language.rawValue)"
        guard cachedVoiceKey != key else { return }

        let started = Date()
        if tts.loadPromptCache(voice: speaker.rawValue, language: language.rawValue) == nil {
            try await tts.buildPromptCache(speaker: speaker, language: language)
            try? tts.savePromptCache()   // next launch loads it from disk instead of rebuilding
        }
        cachedVoiceKey = key
        log.info("Voice prompt cache ready in \(Date().timeIntervalSince(started), format: .fixed(precision: 2))s")
    }

    private func load(variant id: String, folder: URL) async throws -> TTSKit {
        if let tts, loadedVariant == id { return tts }
        // Reuse a load that's already running (preload on hotkey press + speak can overlap).
        if let loadingTask, loadingVariant == id { return try await loadingTask.value }

        let variant = TTSModelVariant(rawValue: id) ?? .qwen3TTS_0_6b
        log.info("Loading voice model \(variant.description, privacy: .public)")
        let started = Date()
        let task = Task<TTSKit, Error> {
            let config = TTSKitConfig(model: variant, modelFolder: folder, verbose: false, download: false)
            return try await TTSKit(config)
        }
        loadingTask = task
        loadingVariant = id
        defer { loadingTask = nil; loadingVariant = nil }

        let loaded = try await task.value
        tts = loaded
        loadedVariant = id
        cachedVoiceKey = nil
        log.info("Voice model ready in \(Date().timeIntervalSince(started), format: .fixed(precision: 1))s")
        return loaded
    }

    // MARK: - Speaking

    /// Starts a new spoken answer, replacing anything currently being spoken.
    /// Add text with `enqueue(_:)` as it arrives, then call `finish()`.
    func begin(variant id: String, folder: URL, voice: String, languageCode: String?) {
        stop()

        let (stream, continuation) = AsyncStream<String>.makeStream()
        input = continuation
        let flag = StopFlag()
        stopFlag = flag
        let previous = speakTask
        let speaker = Qwen3Speaker(rawValue: voice) ?? .ryan
        let language = Self.language(for: languageCode)
        let log = log

        speakTask = Task { [weak self] in
            // Let the previous answer tear down its audio before this one starts.
            await previous?.value
            guard let self, !flag.isSet else { return }

            var audio: AudioOutput?
            do {
                try await self.prepare(variant: id, folder: folder, voice: voice, languageCode: languageCode)
                guard let tts = self.tts, !flag.isSet else { return }

                var options = GenerationOptions()
                options.chunkingStrategy = .sentence   // splits long pieces; short sentences stay whole
                options.concurrentWorkerCount = 1      // streaming needs chunks in order
                let maxTokens = options.maxNewTokens
                let decoder = tts.speechDecoder
                let samplesPerFrame = decoder.samplesPerFrame
                let sampleRate = decoder.sampleRate
                let minimumBuffer = decoder.minimumBufferDuration

                let output = tts.audioOutput
                let started = Date()
                var firstAudio = true

                for await text in stream {
                    if flag.isSet { break }
                    let spoken = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !spoken.isEmpty else { continue }

                    if audio == nil {
                        // The engine starts on the first audio chunk, so it doesn't compete with the model.
                        try output.startPlayback(deferEngineStart: true)
                        audio = output
                    }
                    _ = try await tts.generate(
                        text: spoken,
                        voice: speaker.rawValue,
                        language: language.rawValue,
                        options: options,
                        callback: { progress in
                            if flag.isSet { return false }   // stop generating right away
                            if let stepTime = progress.stepTime {
                                // Same adaptive buffering TTSKit's play() uses: tiny buffer on fast Macs,
                                // a bit more on slower ones so the voice doesn't stutter.
                                output.setBufferDuration(PlaybackStrategy.requiredBuffer(
                                    stepTime: stepTime,
                                    maxNewTokens: maxTokens,
                                    samplesPerFrame: samplesPerFrame,
                                    sampleRate: sampleRate,
                                    minimumBuffer: minimumBuffer
                                ))
                            }
                            output.enqueueAudioChunk(progress.audio)
                            return nil
                        }
                    )
                    if firstAudio {
                        firstAudio = false
                        log.info("First sentence generated in \(Date().timeIntervalSince(started), format: .fixed(precision: 2))s")
                    }
                }

                if let audio {
                    await audio.stopPlayback(waitForCompletion: !flag.isSet)
                }
                if !flag.isSet { self.onFinished?() }
            } catch {
                if let audio { await audio.stopPlayback(waitForCompletion: false) }
                if !flag.isSet {
                    log.error("Speech error: \(error.localizedDescription, privacy: .public)")
                    self.onFinished?()   // so the app doesn't think it's still speaking
                }
            }
        }
    }

    /// Adds text to the answer being spoken.
    func enqueue(_ text: String) {
        input?.yield(text)
    }

    /// No more text is coming; the voice finishes what it has, then calls `onFinished`.
    func finish() {
        input?.finish()
        input = nil
    }

    /// Speaks a complete text in one go (used for "Speak again").
    func speak(_ text: String, variant id: String, folder: URL, voice: String, languageCode: String?) {
        begin(variant: id, folder: folder, voice: voice, languageCode: languageCode)
        enqueue(text)
        finish()
    }

    /// Stops speaking right away.
    func stop() {
        stopFlag.set()
        input?.finish()
        input = nil
        speakTask?.cancel()
    }

    func unload() {
        stop()
        tts = nil
        loadedVariant = nil
        cachedVoiceKey = nil
        loadingTask?.cancel()
        loadingTask = nil
        loadingVariant = nil
    }

    /// Qwen3-TTS speaks 10 languages; anything else falls back to English.
    private static func language(for code: String?) -> Qwen3Language {
        switch code {
        case "zh": return .chinese
        case "ja": return .japanese
        case "ko": return .korean
        case "de": return .german
        case "fr": return .french
        case "ru": return .russian
        case "pt": return .portuguese
        case "es": return .spanish
        case "it": return .italian
        default: return .english
        }
    }
}

/// A thread-safe "stop now" switch, readable from TTSKit's audio callback.
final class StopFlag: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: false)
    var isSet: Bool { lock.withLock { $0 } }
    func set() { lock.withLock { $0 = true } }
}
