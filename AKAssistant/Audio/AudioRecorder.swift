import AVFoundation

enum RecorderError: LocalizedError {
    case noInputDevice
    case converterUnavailable
    /// The microphone changed (e.g. AirPods connected) and macOS hasn't settled on its format yet.
    case deviceChanging

    var errorDescription: String? {
        switch self {
        case .noInputDevice: return "No microphone found"
        case .converterUnavailable: return "Could not convert microphone audio"
        case .deviceChanging: return "The microphone just changed, try again"
        }
    }
}

/// Captures microphone audio into memory as 16 kHz mono Float32 (what Whisper and Parakeet expect).
/// Nothing is written to disk.
final class AudioRecorder {
    static let sampleRate: Double = 16_000

    /// Called on the audio thread with the RMS level of each chunk (0...1).
    var onLevel: ((Float) -> Void)?
    /// Called on the audio thread with each new chunk of 16 kHz audio (for streaming transcription).
    var onSamples: (([Float]) -> Void)?

    /// Rebuilt whenever the audio hardware changes (AirPods connect, another app switches the
    /// input to 16 kHz…). An engine keeps the format it first saw, and tapping it with that stale
    /// format raises an exception macOS won't let us catch.
    private var engine = AVAudioEngine()
    private var configObserver: NSObjectProtocol?
    private var engineIsStale = false
    /// Turning voice processing on makes macOS report a device change; that's us, not a new device,
    /// so don't throw the engine away for it (that made every press pay the full start-up cost).
    private var ignoreConfigChangesUntil = Date.distantPast
    /// Starting the microphone can take a moment; it happens here so the app (and the popup) never wait.
    private let queue = DispatchQueue(label: "com.natfirst.akassistant.recorder", qos: .userInteractive)
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: AudioRecorder.sampleRate,
        channels: 1,
        interleaved: false
    )!
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private let lock = NSLock()
    private(set) var isRecording = false

    init() {
        watch(engine)
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
    }

    /// Removes the Mac's own sound (music, videos, calls, the assistant's voice) that the speakers
    /// play into the microphone, using Apple's voice processing (the echo cancellation FaceTime uses).
    /// Set before `start()`; AppState copies it from Settings.
    var echoCancellation = true

    /// Starts recording without blocking the caller. `completion` gets an error if the mic couldn't start.
    func startInBackground(completion: @escaping (Error?) -> Void) {
        queue.async { [self] in
            do {
                try start()
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }

    private func start() throws {
        guard !isRecording else { return }

        lock.lock()
        samples.removeAll(keepingCapacity: true)
        let stale = engineIsStale
        lock.unlock()

        // Switching echo cancellation off needs a fresh engine (it stays on for the engine's lifetime).
        if stale || (!echoCancellation && engine.inputNode.isVoiceProcessingEnabled) { rebuildEngine() }

        if echoCancellation {
            do {
                try startMicrophone(voiceProcessing: true)
                isRecording = true
                return
            } catch {
                // Some devices (or a device switching right now) can't do voice processing:
                // record the plain microphone rather than nothing.
                NSLog("AK Assistant: echo cancellation unavailable (\(error.localizedDescription)); using the plain microphone")
                rebuildEngine()
            }
        }
        try startMicrophone(voiceProcessing: false)
        isRecording = true
    }

    /// Taps the microphone on the current engine and starts it.
    private func startMicrophone(voiceProcessing: Bool) throws {
        var input = engine.inputNode
        if voiceProcessing {
            lock.lock()
            ignoreConfigChangesUntil = Date().addingTimeInterval(2)
            lock.unlock()
            try input.setVoiceProcessingEnabled(true)
            // Don't turn other apps' audio down while we listen (macOS does by default).
            input.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
            // Voice processing runs input and output as one unit, so the output side must run too:
            // route the mic into the muted mixer so the engine has a complete input → output path.
            let mixer = engine.mainMixerNode
            mixer.outputVolume = 0
            engine.connect(input, to: mixer, format: input.outputFormat(forBus: 0))
        }

        var inputFormat = input.outputFormat(forBus: 0)
        // Without voice processing, the tap's format must match what the hardware delivers right now;
        // if the engine still has an old one, start again with a fresh engine.
        if !voiceProcessing && !Self.matches(inputFormat, input.inputFormat(forBus: 0)) {
            rebuildEngine()
            input = engine.inputNode
            inputFormat = input.outputFormat(forBus: 0)
        }
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecorderError.noInputDevice
        }
        guard voiceProcessing || Self.matches(inputFormat, input.inputFormat(forBus: 0)) else {
            throw RecorderError.deviceChanging
        }

        // With voice processing, channel 0 is the cleaned-up voice; the other channels must not be mixed in.
        let firstChannelOnly = voiceProcessing && inputFormat.channelCount > 1
        let converterInput = firstChannelOnly
            ? AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputFormat.sampleRate, channels: 1, interleaved: false)!
            : inputFormat
        guard let converter = AVAudioConverter(from: converterInput, to: targetFormat) else {
            throw RecorderError.converterUnavailable
        }
        self.converter = converter

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let source = firstChannelOnly ? (Self.firstChannel(of: buffer, format: converterInput) ?? buffer) : buffer
            self.process(source)
        }

        engine.prepare()
        try engine.start()
    }

    /// A mono copy of a buffer's first channel.
    private static func firstChannel(of buffer: AVAudioPCMBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let source = buffer.floatChannelData?[0],
              let mono = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength),
              let target = mono.floatChannelData?[0] else { return nil }
        mono.frameLength = buffer.frameLength
        target.update(from: source, count: Int(buffer.frameLength))
        return mono
    }

    /// Stops capture and returns everything recorded since `start()`. If the mic is still starting,
    /// this waits for that to finish first.
    func stop() -> [Float] {
        queue.sync { stopNow() }
    }

    private func stopNow() -> [Float] {
        guard isRecording else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        converter = nil

        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    /// A copy of what's been recorded so far (optionally just the last few seconds), for the live transcript.
    func snapshot(lastSeconds: Double? = nil) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        guard let lastSeconds else { return samples }
        let count = Int(lastSeconds * Self.sampleRate)
        return samples.count > count ? Array(samples.suffix(count)) : samples
    }

    /// Same sample rate and channel count (the parts a tap is checked against).
    static func matches(_ a: AVAudioFormat, _ b: AVAudioFormat) -> Bool {
        a.sampleRate == b.sampleRate && a.channelCount == b.channelCount
    }

    private func rebuildEngine() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        engine.reset()
        engine = AVAudioEngine()
        watch(engine)
        lock.lock()
        engineIsStale = false
        lock.unlock()
    }

    /// macOS posts this when the input or output device, or its format, changes.
    private func watch(_ engine: AVAudioEngine) {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            if Date() > self.ignoreConfigChangesUntil { self.engineIsStale = true }
            self.lock.unlock()
        }
    }

    /// Seconds recorded so far.
    var recordedSeconds: Double {
        lock.lock()
        defer { lock.unlock() }
        return Double(samples.count) / Self.sampleRate
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = output.floatChannelData?[0], output.frameLength > 0 else { return }

        let chunk = Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
        lock.lock()
        samples.append(contentsOf: chunk)
        lock.unlock()

        onSamples?(chunk)
        onLevel?(min(1, AudioRecorder.rms(chunk) * 8))
    }

    static func rms(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        var sum: Float = 0
        for v in values { sum += v * v }
        return (sum / Float(values.count)).squareRoot()
    }
}
