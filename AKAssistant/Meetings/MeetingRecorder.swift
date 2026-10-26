import AVFoundation
import CoreMedia
import ScreenCaptureKit
import os

/// Records a meeting: your microphone plus (optionally) the Mac's own audio, so the other people
/// on Zoom / Meet / Teams are captured even when you wear headphones.
///
/// - Both sources are converted to 16 kHz mono on one shared timeline.
/// - Three .m4a files can be written as it records (nothing is held in memory for long, so an
///   hour-long meeting is fine): the mix (for playback), the mic alone ("You") and the Mac's audio
///   alone (the others). The separate tracks give a cleaner final transcript and speaker labels.
/// - The mic can use Apple's voice processing (the FaceTime noise suppression and echo cancellation).
/// - Every 15–28 seconds, cut at a pause where possible, a chunk is handed to `onChunk` so the
///   transcript builds up while the meeting is still going.
final class MeetingRecorder {
    static let sampleRate = AudioRecorder.sampleRate

    /// Where to write audio. nil = don't write that file.
    struct Outputs {
        var mixed: URL?
        var mic: URL?
        var mac: URL?
    }

    /// Mixer queue. RMS level of the mix (0...1).
    var onLevel: ((Float) -> Void)?
    /// Mixer queue. A piece of the meeting and where it starts (seconds from the beginning).
    var onChunk: ((_ samples: [Float], _ startSeconds: Double) -> Void)?

    /// Set after `start` if the Mac's audio couldn't be captured (usually the permission).
    private(set) var systemAudioError: String?
    /// The Mac's audio is being recorded (its track file exists).
    private(set) var systemAudioActive = false
    /// Noise suppression / echo cancellation is on for the mic.
    private(set) var voiceProcessingActive = false
    /// Set when voice processing was asked for but macOS couldn't start it (the mic is recorded without it).
    private(set) var voiceProcessingError: String?

    /// Replaced with a fresh one if starting with voice processing fails.
    private var engine = AVAudioEngine()
    private let micResampler = MonoResampler()
    private var systemCapture: SystemAudioCapture?

    private let queue = DispatchQueue(label: "com.natfirst.akassistant.meeting-mixer")
    private var timer: DispatchSourceTimer?
    private let lock = NSLock()
    private var micQueue: [Float] = []
    private var systemQueue: [Float] = []

    // Mixer-queue state.
    private var mixedFile: AVAudioFile?
    private var micFile: AVAudioFile?
    private var macFile: AVAudioFile?
    private var systemActive = false
    private var pending: [Float] = []
    private var pendingStart: Double = 0
    private var totalSamples = 0

    private let log = Logger(subsystem: "com.natfirst.akassistant", category: "Meeting")

    /// Seconds mixed so far.
    var recordedSeconds: Double {
        queue.sync { Double(totalSamples) / Self.sampleRate }
    }

    /// Starts recording.
    func start(outputs: Outputs, captureSystemAudio: Bool, voiceProcessing: Bool) async throws {
        lock.lock(); micQueue.removeAll(); systemQueue.removeAll(); lock.unlock()
        queue.sync {
            pending.removeAll(); pendingStart = 0; totalSamples = 0
            mixedFile = Self.makeFile(outputs.mixed, log: log)
            micFile = Self.makeFile(outputs.mic, log: log)
            macFile = nil
            systemActive = false
        }

        // Microphone, optionally with Apple's voice processing: noise suppression plus echo
        // cancellation (removes the call's audio that leaks from your speakers into the mic).
        // Voice processing fails to start on some setups (error -10875: often Bluetooth headphones
        // or a mic and speaker at different sample rates). Then the mic is recorded without it.
        voiceProcessingActive = false
        voiceProcessingError = nil
        if voiceProcessing {
            do {
                try startMicrophone(voiceProcessing: true)
                voiceProcessingActive = true
            } catch {
                log.error("Voice processing failed to start, using the plain mic: \(error.localizedDescription, privacy: .public)")
                voiceProcessingError = "Noise reduction couldn't start with this microphone and speaker setup (this often happens with Bluetooth headphones), so the mic was recorded without it. The clean-up pass still filters noise."
                resetEngine()
                try startMicrophone(voiceProcessing: false)
            }
        } else {
            do {
                try startMicrophone(voiceProcessing: false)
            } catch RecorderError.deviceChanging {
                resetEngine()   // a fresh engine reads the current format
                try startMicrophone(voiceProcessing: false)
            }
        }

        // The Mac's audio (other participants). Recording carries on with the mic if this fails.
        systemAudioError = nil
        systemAudioActive = false
        if captureSystemAudio {
            let capture = SystemAudioCapture()
            capture.onSamples = { [weak self] samples in
                guard let self else { return }
                self.lock.lock()
                self.systemQueue.append(contentsOf: samples)
                self.lock.unlock()
            }
            do {
                try await capture.start()
                systemCapture = capture
                systemAudioActive = true
                queue.sync {
                    macFile = Self.makeFile(outputs.mac, log: log)
                    systemActive = true
                }
            } catch {
                systemAudioError = "Only your microphone was recorded. Allow AK Assistant in System Settings › Privacy & Security › Screen & System Audio Recording to also record the other people."
                log.error("System audio capture failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in self?.mix(final: false) }
        timer.resume()
        self.timer = timer
    }

    /// Stops recording, hands over the last chunk and closes the audio file. Returns the length in seconds.
    func stop() async -> Double {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if let systemCapture {
            await systemCapture.stop()
            self.systemCapture = nil
        }
        timer?.cancel()
        timer = nil
        return queue.sync {
            mix(final: true)
            // AVAudioFile finishes each .m4a when it's released.
            mixedFile = nil
            micFile = nil
            macFile = nil
            return Double(totalSamples) / Self.sampleRate
        }
    }

    // MARK: - Mixing (mixer queue)

    private func mix(final: Bool) {
        lock.lock()
        var mic = micQueue
        micQueue.removeAll(keepingCapacity: true)
        var count = mic.count
        // No microphone audio (e.g. it was unplugged): keep going on the Mac's audio alone.
        if count == 0, systemQueue.count > Int(Self.sampleRate / 2) { count = systemQueue.count }
        if final { count = max(count, systemQueue.count) }
        let takeSystem = min(count, systemQueue.count)
        let system = Array(systemQueue.prefix(takeSystem))
        systemQueue.removeFirst(takeSystem)
        // The two clocks drift a little; never let the Mac's audio fall more than a second behind.
        let maxBacklog = Int(Self.sampleRate)
        if systemQueue.count > maxBacklog { systemQueue.removeFirst(systemQueue.count - maxBacklog) }
        lock.unlock()

        if count > 0 {
            if mic.count < count { mic += [Float](repeating: 0, count: count - mic.count) }
            var mixed = mic
            for i in 0..<system.count {
                mixed[i] = max(-1, min(1, mixed[i] + system[i]))
            }
            write(mixed, to: &mixedFile)
            write(mic, to: &micFile)
            if systemActive {
                // Same length as the mic so both tracks share one timeline.
                let padded = system.count < count ? system + [Float](repeating: 0, count: count - system.count) : system
                write(padded, to: &macFile)
            }
            totalSamples += mixed.count
            pending += mixed
            onLevel?(min(1, AudioRecorder.rms(mixed) * 8))
        }
        cutChunks(final: final)
    }

    /// Taps the mic on the current engine and starts it.
    private func startMicrophone(voiceProcessing: Bool) throws {
        let input = engine.inputNode
        if voiceProcessing {
            try input.setVoiceProcessingEnabled(true)
            // Don't turn other apps' audio down while it's on (macOS does by default).
            input.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
            // Voice processing runs input and output as one unit, so the output side must be running:
            // route the mic into the (muted) mixer so the engine has a complete input → output path.
            let mixer = engine.mainMixerNode
            mixer.outputVolume = 0
            engine.connect(input, to: mixer, format: input.outputFormat(forBus: 0))
        }
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecorderError.noInputDevice
        }
        // Tapping with a format the hardware no longer delivers raises an uncatchable exception.
        guard voiceProcessing || AudioRecorder.matches(inputFormat, input.inputFormat(forBus: 0)) else {
            throw RecorderError.deviceChanging
        }
        let firstChannelOnly = voiceProcessing && inputFormat.channelCount > 1
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            // With voice processing, channel 0 is the cleaned voice; the others aren't meant to be mixed in.
            let source = firstChannelOnly ? (Self.firstChannel(of: buffer) ?? buffer) : buffer
            let samples = self.micResampler.convert(source)
            guard !samples.isEmpty else { return }
            self.lock.lock()
            self.micQueue.append(contentsOf: samples)
            self.lock.unlock()
        }
        engine.prepare()
        try engine.start()
    }

    /// Throws away an engine left half-configured by a failed start and makes a clean one.
    private func resetEngine() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        engine.reset()
        engine = AVAudioEngine()
        lock.lock(); micQueue.removeAll(); lock.unlock()
    }

    private static func makeFile(_ url: URL?, log: Logger) -> AVAudioFile? {
        guard let url else { return nil }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
        do {
            return try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            log.error("Couldn't create meeting audio file: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// A mono copy of channel 0 (Float32, non-interleaved input).
    private static func firstChannel(of buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let source = buffer.floatChannelData?[0],
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate,
                                         channels: 1, interleaved: false),
              let mono = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength),
              let target = mono.floatChannelData?[0] else { return nil }
        mono.frameLength = buffer.frameLength
        target.update(from: source, count: Int(buffer.frameLength))
        return mono
    }

    private func write(_ samples: [Float], to file: inout AVAudioFile?) {
        guard let current = file, !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: current.processingFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        do {
            try current.write(from: buffer)
        } catch {
            log.error("Meeting audio write failed: \(error.localizedDescription, privacy: .public)")
            file = nil
        }
    }

    /// Hands finished pieces to the transcriber, cutting at a pause where possible.
    private func cutChunks(final: Bool) {
        let rate = Int(Self.sampleRate)
        let minLength = 15 * rate, softLength = 18 * rate, maxLength = 28 * rate

        if final {
            if !pending.isEmpty { emit(pending.count) }
            return
        }
        if pending.count >= softLength && pending.count < maxLength {
            // Cut right away if the last moment is quiet (someone just stopped talking).
            let tail = Array(pending.suffix(rate * 2 / 5))
            if AudioRecorder.rms(tail) < 0.008 { emit(pending.count) }
            return
        }
        guard pending.count >= maxLength else { return }
        // Too long: cut at the quietest fifth of a second between 15 s and 28 s.
        let window = rate / 5
        var best = maxLength
        var bestLevel = Float.greatestFiniteMagnitude
        var i = minLength
        while i + window <= maxLength {
            let level = AudioRecorder.rms(Array(pending[i..<(i + window)]))
            if level < bestLevel {
                bestLevel = level
                best = i + window / 2
            }
            i += window / 2
        }
        emit(best)
    }

    private func emit(_ count: Int) {
        let chunk = Array(pending.prefix(count))
        pending.removeFirst(count)
        let start = pendingStart
        pendingStart += Double(count) / Self.sampleRate
        onChunk?(chunk, start)
    }
}

// MARK: - Resampling

/// Converts any PCM buffer to 16 kHz mono Float32, mixing stereo down.
final class MonoResampler {
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioRecorder.sampleRate,
                                       channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        if converter == nil || inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
            converter?.downmix = true
            inputFormat = buffer.format
        }
        guard let converter, buffer.frameLength > 0 else { return [] }

        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return [] }

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
        guard error == nil, let channel = output.floatChannelData?[0], output.frameLength > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}

// MARK: - The Mac's own audio

/// Captures everything the Mac plays (except AK Assistant itself) with ScreenCaptureKit.
/// Needs the "Screen & System Audio Recording" permission; macOS asks the first time.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    /// Sample-handler queue. 16 kHz mono audio.
    var onSamples: (([Float]) -> Void)?

    private var stream: SCStream?
    private let resampler = MonoResampler()
    private let queue = DispatchQueue(label: "com.natfirst.akassistant.system-audio")
    private let log = Logger(subsystem: "com.natfirst.akassistant", category: "Meeting")

    func start() async throws {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw NSError(domain: "AKAssistant", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display to capture audio from"])
        }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true   // don't record AK Assistant's own voice
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        // ScreenCaptureKit always captures video too; keep it as small and slow as possible.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.showsCursor = false

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)   // frames are ignored
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              let pcm = Self.pcmBuffer(from: sampleBuffer) else { return }
        let samples = resampler.convert(pcm)
        if !samples.isEmpty { onSamples?(samples) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log.error("System audio stream stopped: \(error.localizedDescription, privacy: .public)")
    }

    /// Copies a ScreenCaptureKit audio sample buffer into an AVAudioPCMBuffer we own.
    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = sampleBuffer.formatDescription,
              var streamDescription = description.audioStreamBasicDescription,
              let format = AVAudioFormat(streamDescription: &streamDescription) else { return nil }
        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        pcm.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList)
        return status == noErr ? pcm : nil
    }
}
