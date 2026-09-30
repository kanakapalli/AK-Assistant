import AVFoundation

enum RecorderError: LocalizedError {
    case noInputDevice
    case converterUnavailable

    var errorDescription: String? {
        switch self {
        case .noInputDevice: return "No microphone found"
        case .converterUnavailable: return "Could not convert microphone audio"
        }
    }
}

/// Captures microphone audio into memory as 16 kHz mono Float32 (what Whisper and Parakeet expect).
/// Nothing is written to disk.
final class AudioRecorder {
    static let sampleRate: Double = 16_000

    /// Called on the audio thread with the RMS level of each chunk (0...1).
    var onLevel: ((Float) -> Void)?

    private let engine = AVAudioEngine()
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

    func start() throws {
        guard !isRecording else { return }

        lock.lock()
        samples.removeAll(keepingCapacity: true)
        lock.unlock()

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecorderError.noInputDevice
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw RecorderError.converterUnavailable
        }
        self.converter = converter

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }

        engine.prepare()
        try engine.start()
        isRecording = true
    }

    /// Stops capture and returns everything recorded since `start()`.
    func stop() -> [Float] {
        guard isRecording else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        converter = nil

        lock.lock()
        defer { lock.unlock() }
        return samples
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

        onLevel?(min(1, AudioRecorder.rms(chunk) * 8))
    }

    static func rms(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        var sum: Float = 0
        for v in values { sum += v * v }
        return (sum / Float(values.count)).squareRoot()
    }
}
