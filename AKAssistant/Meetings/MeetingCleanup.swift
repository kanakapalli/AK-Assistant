import Foundation
import AVFoundation
import FluidAudio
import os

/// The after-meeting pass that replaces the rough live transcript with a cleaner one, with speakers:
///
/// 1. **Speakers** (FluidAudio's offline diarizer, on this Mac): the Mac's audio track is split into
///    who-spoke-when, "Speaker 1", "Speaker 2"… Your mic track is "You". For an in-person meeting
///    (mic only) the mic track itself is split into speakers.
/// 2. **Speech detection** (Silero VAD): cuts each track at real pauses instead of every ~20 seconds,
///    and skips silence and noise-only stretches, so the speech model doesn't invent words.
/// 3. **Transcription** of each piece, from the separate tracks (no echo, no talking over each other in one stream).
/// 4. **Echo filter**: drops mic lines that are just the call leaking from your speakers into the mic.
/// 5. Consecutive lines from the same speaker are joined into paragraphs.
@MainActor
final class MeetingCleanup {
    /// Settings › Meetings choices that affect the clean-up.
    struct Options {
        var identifySpeakers = true
        /// People in the meeting including you; nil = automatic.
        var expectedSpeakers: Int? = nil
        var removeEcho = true
        /// Silero VAD threshold (see `SpeechSensitivity`).
        var speechThreshold: Float = 0.7
    }

    struct Result {
        var segments: [TranscriptSegment]
        var speakerNames: [String: String]
        /// Something didn't fully work (e.g. the speaker model couldn't be downloaded).
        var problem: String?
    }

    private struct Piece {
        var start: Double
        var end: Double
        var speaker: String?
    }

    /// Longest piece handed to the speech model (Whisper reads 30 s at a time).
    private let maxPieceSeconds: Double = 25

    private var vad: VadManager?
    private var vadThreshold: Float?
    private var diarizer: OfflineDiarizerManager?
    /// Speaker count the cached diarizer was made for (nil = automatic).
    private var diarizerSpeakers: Int?? = .none
    private var options = Options()
    private let log = Logger(subsystem: "com.natfirst.akassistant", category: "Meeting")

    func run(micURL: URL?, macURL: URL?, options: Options, model: SpeechModel, language: String?,
             removeFillers: Bool, transcriber: TranscriptionService, modelManager: ModelManager,
             progress: (String) -> Void) async throws -> Result {
        self.options = options
        let identifySpeakers = options.identifySpeakers
        var problems: [String] = []
        var micPieces: [Piece] = []
        var macPieces: [Piece] = []
        let started = Date()

        // The other people (the Mac's audio).
        if let macURL {
            if identifySpeakers {
                progress("Telling speakers apart…")
                do {
                    // You are on the mic, so the Mac's audio has one person fewer.
                    macPieces = try await diarize(macURL, speakers: options.expectedSpeakers.map { max(1, $0 - 1) })
                } catch {
                    log.error("Diarization failed: \(error.localizedDescription, privacy: .public)")
                    problems.append("Speakers couldn't be told apart (\(error.localizedDescription)).")
                }
            }
            if macPieces.isEmpty {
                progress("Finding speech…")
                macPieces = try await speechPieces(macURL, speaker: MeetingSpeakers.others)
            }
        }

        // You (the mic). Mic only means an in-person meeting: everyone is on the mic.
        if let micURL {
            if macURL == nil && identifySpeakers {
                progress("Telling speakers apart…")
                do {
                    micPieces = try await diarize(micURL, speakers: options.expectedSpeakers)
                } catch {
                    log.error("Diarization failed: \(error.localizedDescription, privacy: .public)")
                    problems.append("Speakers couldn't be told apart (\(error.localizedDescription)).")
                }
            }
            if micPieces.isEmpty {
                progress("Finding speech…")
                micPieces = try await speechPieces(micURL, speaker: macURL == nil ? nil : MeetingSpeakers.you)
            }
        }

        // Transcribe every piece.
        let total = max(1, micPieces.count + macPieces.count)
        var done = 0
        var micSegments: [TranscriptSegment] = []
        var macSegments: [TranscriptSegment] = []
        for (url, pieces, isMic) in [(micURL, micPieces, true), (macURL, macPieces, false)] {
            guard let url, !pieces.isEmpty else { continue }
            let reader = try AudioTrackReader(url: url)
            for piece in pieces {
                try Task.checkCancellation()
                done += 1
                if done == 1 || done % 4 == 0 {
                    progress("Cleaning up the transcript… \(min(99, done * 100 / total))%")
                }
                for part in await split(piece, reader: reader) {
                    guard part.end - part.start >= 0.5 else { continue }   // tiny clips make Whisper invent words
                    let samples = reader.read(from: part.start, to: part.end)
                    guard samples.count >= Int(AudioRecorder.sampleRate * 0.4), AudioRecorder.rms(samples) > 0.002 else { continue }
                    guard let raw = try? await transcriber.transcribe(samples, model: model, language: language, modelManager: modelManager) else { continue }
                    let text = PostProcessor.clean(raw, removeFillers: removeFillers)
                    guard !text.isEmpty else { continue }
                    let segment = TranscriptSegment(start: part.start, end: part.end, text: text, speaker: part.speaker)
                    if isMic { micSegments.append(segment) } else { macSegments.append(segment) }
                }
            }
        }

        // The call leaking from the speakers into the mic shows up as "You" repeating the others.
        let beforeEcho = micSegments.count
        if options.removeEcho && !macSegments.isEmpty {
            micSegments.removeAll { Self.isEcho($0, of: macSegments) }
        }
        if beforeEcho != micSegments.count {
            log.info("Dropped \(beforeEcho - micSegments.count) echoed mic lines")
        }

        let segments = Self.paragraphs(from: (micSegments + macSegments).sorted { $0.start < $1.start })
        var names: [String: String] = [:]
        for id in Set(segments.compactMap(\.speaker)) {
            names[id] = MeetingSpeakers.defaultName(for: id)
        }
        log.info("Clean-up pass: \(segments.count) paragraphs, \(names.count) speakers in \(Date().timeIntervalSince(started), format: .fixed(precision: 1))s")
        return Result(segments: segments, speakerNames: names, problem: problems.first)
    }

    // MARK: - Speakers

    /// Who spoke when, as pieces labelled "s1", "s2"… in order of first appearance.
    private func diarize(_ url: URL, speakers: Int?) async throws -> [Piece] {
        // The speaker count is part of the diarizer's configuration: make a new one when it changes.
        let manager: OfflineDiarizerManager
        if let cached = diarizer, diarizerSpeakers == .some(speakers) {
            manager = cached
        } else {
            var config = OfflineDiarizerConfig.default
            config.clustering.numSpeakers = speakers
            manager = OfflineDiarizerManager(config: config)
        }
        try await manager.prepareModels()   // downloads the models the first time (~30 MB)
        diarizer = manager
        diarizerSpeakers = .some(speakers)
        let result = try await manager.process(url)

        var numbers: [String: Int] = [:]
        var turns: [Piece] = []
        for segment in result.segments.sorted(by: { $0.startTimeSeconds < $1.startTimeSeconds }) {
            let start = Double(segment.startTimeSeconds)
            let end = Double(segment.endTimeSeconds)
            guard end - start >= 0.3 else { continue }
            if numbers[segment.speakerId] == nil { numbers[segment.speakerId] = numbers.count + 1 }
            let id = MeetingSpeakers.id(forNumber: numbers[segment.speakerId] ?? 1)
            turns.append(Piece(start: start, end: end, speaker: id))
        }
        // Join a speaker's turns separated by short gaps, up to the piece limit.
        var merged: [Piece] = []
        for turn in turns {
            if var last = merged.last, last.speaker == turn.speaker,
               turn.start - last.end < 0.8, turn.end - last.start <= maxPieceSeconds {
                last.end = max(last.end, turn.end)
                merged[merged.count - 1] = last
            } else {
                merged.append(turn)
            }
        }
        return merged
    }

    // MARK: - Speech detection

    private func vadManager() async throws -> VadManager {
        if let vad, vadThreshold == options.speechThreshold { return vad }
        let manager = try await VadManager(config: VadConfig(defaultThreshold: options.speechThreshold))
        vad = manager
        vadThreshold = options.speechThreshold
        return manager
    }

    private var segmentation: VadSegmentationConfig {
        VadSegmentationConfig(minSpeechDuration: 0.25, minSilenceDuration: 0.6,
                              maxSpeechDuration: maxPieceSeconds, speechPadding: 0.15)
    }

    /// Speech in a whole track, read 10 minutes at a time to keep memory low.
    private func speechPieces(_ url: URL, speaker: String?) async throws -> [Piece] {
        let reader = try AudioTrackReader(url: url)
        let vad = try await vadManager()
        let window: Double = 600
        let length = reader.duration
        var position: Double = 0
        var pieces: [Piece] = []
        while position < length - 0.1 {
            try Task.checkCancellation()
            let end = min(length, position + window)
            let from = position
            let samples = await Task.detached { reader.read(from: from, to: end) }.value
            guard !samples.isEmpty else { break }
            let found = try await vad.segmentSpeech(samples, config: segmentation)
            var next = end
            let isLastWindow = end >= length - 0.01
            for (index, segment) in found.enumerated() {
                // Speech running into the window's end: start the next window at it instead of cutting it.
                if !isLastWindow, index == found.count - 1, segment.endTime >= (end - position) - 0.5, segment.startTime > 1 {
                    next = position + segment.startTime
                    break
                }
                pieces.append(Piece(start: position + segment.startTime, end: position + segment.endTime, speaker: speaker))
            }
            position = next > position ? next : end
        }
        return pieces
    }

    /// Long pieces are cut at their pauses (or evenly, if that fails) so each fits the speech model.
    private func split(_ piece: Piece, reader: AudioTrackReader) async -> [Piece] {
        let length = piece.end - piece.start
        guard length > maxPieceSeconds + 1 else { return [piece] }
        if let vad = try? await vadManager() {
            let samples = reader.read(from: piece.start, to: piece.end)
            if let found = try? await vad.segmentSpeech(samples, config: segmentation), !found.isEmpty {
                return found.map { Piece(start: piece.start + $0.startTime, end: piece.start + $0.endTime, speaker: piece.speaker) }
            }
        }
        let parts = Int((length / maxPieceSeconds).rounded(.up))
        let step = length / Double(parts)
        return (0..<parts).map { i in
            Piece(start: piece.start + Double(i) * step, end: piece.start + Double(i + 1) * step, speaker: piece.speaker)
        }
    }

    // MARK: - Tidying

    /// A mic line mostly overlapping in time with the others' speech and repeating their words.
    private static func isEcho(_ line: TranscriptSegment, of others: [TranscriptSegment]) -> Bool {
        let overlapping = others.filter { $0.start < line.end && $0.end > line.start }
        guard !overlapping.isEmpty else { return false }
        let overlap = overlapping.reduce(0.0) { $0 + min($1.end, line.end) - max($1.start, line.start) }
        guard overlap / max(0.1, line.end - line.start) > 0.5 else { return false }
        let mine = words(line.text)
        guard !mine.isEmpty else { return true }
        let theirs = words(overlapping.map(\.text).joined(separator: " "))
        return Double(mine.intersection(theirs).count) / Double(mine.count) > 0.6
    }

    private static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
    }

    /// Joins consecutive lines from the same speaker (short gap, under a minute) into one paragraph.
    private static func paragraphs(from lines: [TranscriptSegment]) -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        for line in lines {
            if var last = result.last, last.speaker == line.speaker,
               line.start - last.end < 1.5, line.end - last.start < 60 {
                last.end = max(last.end, line.end)
                last.text += " " + line.text
                result[result.count - 1] = last
            } else {
                result.append(line)
            }
        }
        return result
    }
}

/// Reads stretches of a meeting track as 16 kHz mono samples.
final class AudioTrackReader: @unchecked Sendable {
    private let file: AVAudioFile
    private let lock = NSLock()
    private let rate: Double

    init(url: URL) throws {
        file = try AVAudioFile(forReading: url)
        rate = file.processingFormat.sampleRate
    }

    var duration: Double { Double(file.length) / rate }

    func read(from start: Double, to end: Double) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let startFrame = AVAudioFramePosition(max(0, start) * rate)
        guard startFrame < file.length, end > start else { return [] }
        let wanted = min(Double(file.length - startFrame), (end - max(0, start)) * rate)
        let count = AVAudioFrameCount(max(0, wanted))
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else { return [] }
        do {
            file.framePosition = startFrame
            try file.read(into: buffer, frameCount: count)
        } catch {
            return []
        }
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}
