import AVFoundation
import os

/// Captures the Mac's speaker output (excluding Duck Keyboard's own voice) and segments it
/// into speech chunks for translation. The extended two-person live-translation feature.
///
/// Uses the same ScreenCaptureKit-based SystemAudioCapture that meetings use.
/// Needs the Screen & System Audio Recording permission.
///
/// Flow: system audio → VAD (RMS threshold) → speech segment → onSpeechChunk callback
/// AppState owns this object and handles transcription + translation + TTS.
@MainActor
final class LiveAudioTranslator {
    /// Called on MainActor when a complete speech segment is ready (16 kHz mono Float32).
    var onSpeechChunk: (([Float]) -> Void)?

    private var capture: SystemAudioCapture?
    private var audioBuffer: [Float] = []
    private var silenceSamples: Int = 0
    private var hasSpeech: Bool = false
    /// Suppress incoming chunks while our TTS is speaking to avoid translating our own voice.
    private(set) var isSuppressed: Bool = false

    private static let sampleRate: Double = AudioRecorder.sampleRate

    /// Minimum RMS that counts as speech (system audio often has background hiss).
    private static let speechThreshold: Float = 0.004
    /// At least this many samples of speech before we start a segment (0.3 s).
    private static let minSpeechSamples: Int = Int(sampleRate * 0.3)
    /// Silence for this long after speech ends the segment (0.8 s).
    private static let silenceEndSamples: Int = Int(sampleRate * 0.8)
    /// Hard cap on a segment so we don't hold too long in memory (12 s).
    private static let maxSegmentSamples: Int = Int(sampleRate * 12)

    private let log = Logger(subsystem: "com.natfirst.akassistant", category: "LiveTranslation")

    var isCapturing: Bool { capture != nil }

    func start() async throws {
        guard capture == nil else { return }
        reset()
        let cap = SystemAudioCapture()
        cap.onSamples = { [weak self] samples in
            Task { @MainActor in self?.process(samples) }
        }
        try await cap.start()
        capture = cap
        log.info("Live audio translation started")
    }

    func stop() async {
        guard let cap = capture else { return }
        capture = nil
        reset()
        await cap.stop()
        log.info("Live audio translation stopped")
    }

    /// Call before your TTS starts playing so the translator ignores its own speech output.
    func suppress() { isSuppressed = true }

    /// Call when TTS finishes so the translator resumes.
    func unsuppress() {
        isSuppressed = false
        reset()
    }

    private func reset() {
        audioBuffer.removeAll(keepingCapacity: true)
        silenceSamples = 0
        hasSpeech = false
    }

    private func process(_ samples: [Float]) {
        guard !isSuppressed else { return }
        let rms = AudioRecorder.rms(samples)
        let isSpeechNow = rms > Self.speechThreshold

        if isSpeechNow {
            audioBuffer.append(contentsOf: samples)
            hasSpeech = true
            silenceSamples = 0

            if audioBuffer.count >= Self.maxSegmentSamples {
                flush()
            }
        } else if hasSpeech {
            audioBuffer.append(contentsOf: samples)
            silenceSamples += samples.count

            if silenceSamples >= Self.silenceEndSamples {
                flush()
            }
        }
    }

    private func flush() {
        let chunk = audioBuffer
        reset()
        guard chunk.count >= Self.minSpeechSamples else { return }
        log.debug("Speech segment: \(Double(chunk.count) / Self.sampleRate, format: .fixed(precision: 1))s")
        onSpeechChunk?(chunk)
    }
}
