import AppKit
import SwiftData
import Observation
import os

/// Runs meeting mode: record → transcribe as you go → summary and to-dos when it ends.
/// Started by double-tapping the dictation key (or from the Meetings screen / menu bar);
/// a single press of the dictation key stops it.
@MainActor
@Observable
final class MeetingCoordinator {
    private(set) var isRecording = false
    private(set) var startedAt: Date?
    private(set) var level: Float = 0
    /// The meeting being recorded right now.
    private(set) var activeMeetingID: UUID?
    /// Meetings whose transcript or notes are still being written, with a short status line.
    private(set) var progress: [UUID: String] = [:]
    /// When the last meeting was stopped (the second tap of a double tap right after shouldn't start a new one).
    private(set) var lastStoppedAt: Date?

    /// Short messages for the popup ("Meeting started", errors…).
    @ObservationIgnored var onFlash: (@MainActor (DictationStatus) -> Void)?

    @ObservationIgnored private var preferences: Preferences!
    @ObservationIgnored private var modelManager: ModelManager!
    @ObservationIgnored private var transcriber: TranscriptionService!
    @ObservationIgnored private var llm: LLMService!
    @ObservationIgnored private var container: ModelContainer!

    @ObservationIgnored private var recorder: MeetingRecorder?
    @ObservationIgnored private var meeting: Meeting?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var chunkInput: AsyncStream<(samples: [Float], start: Double)>.Continuation?
    @ObservationIgnored private var transcribeTask: Task<Void, Never>?
    @ObservationIgnored private var maxDurationTask: Task<Void, Never>?
    @ObservationIgnored private var summaryTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private let cleanup = MeetingCleanup()

    private let log = Logger(subsystem: "com.natfirst.akassistant", category: "Meeting")
    /// Safety stop for a forgotten recording.

    private var context: ModelContext { container.mainContext }

    func attach(preferences: Preferences, modelManager: ModelManager, transcriber: TranscriptionService,
                llm: LLMService, container: ModelContainer) {
        self.preferences = preferences
        self.modelManager = modelManager
        self.transcriber = transcriber
        self.llm = llm
        self.container = container
        recoverInterruptedMeetings()
    }

    // MARK: - Recording

    func start() {
        guard !isRecording, preferences != nil else { return }
        let model = preferences.selectedModel
        guard modelManager.isDownloaded(model) else {
            onFlash?(.error("Download \(model.name) first"))
            return
        }
        guard Permissions.microphoneGranted else {
            onFlash?(.error("Microphone access needed"))
            return
        }

        let meeting = Meeting(speechModelName: model.name)
        if preferences.meetingKeepAudio { meeting.audioFileName = "\(meeting.id.uuidString).m4a" }
        // Separate tracks for the clean-up pass (deleted afterwards unless the audio is kept).
        if preferences.meetingCleanupPass {
            meeting.micTrackFileName = "\(meeting.id.uuidString)-mic.m4a"
            meeting.macTrackFileName = "\(meeting.id.uuidString)-mac.m4a"
        }
        context.insert(meeting)
        save()
        self.meeting = meeting
        activeMeetingID = meeting.id
        startedAt = meeting.startedAt
        isRecording = true
        Sounds.play(.start, enabled: preferences.playSounds)

        // Pieces of audio go to the speech model one at a time, in order.
        let (stream, input) = AsyncStream<(samples: [Float], start: Double)>.makeStream()
        chunkInput = input
        let language = preferences.meetingLanguageCode
        let removeFillers = preferences.removeFillers
        // Live transcript off: the clean-up pass writes the whole transcript at the end instead.
        let live = preferences.meetingLiveTranscript || !preferences.meetingCleanupPass
        transcribeTask = Task { [weak self] in
            for await chunk in stream {
                guard live else { continue }
                await self?.transcribe(chunk.samples, start: chunk.start, model: model, language: language,
                                       removeFillers: removeFillers, into: meeting)
            }
        }
        // Load the speech model now (usually already loaded) so the first piece isn't delayed.
        Task { [transcriber, modelManager] in
            try? await transcriber?.prepare(model: model, modelManager: modelManager!)
        }

        let recorder = MeetingRecorder()
        self.recorder = recorder
        recorder.onLevel = { [weak self] value in
            Task { @MainActor in self?.level = value }
        }
        recorder.onChunk = { samples, start in input.yield((samples: samples, start: start)) }
        let folder = MeetingStorage.folder
        let outputs = MeetingRecorder.Outputs(
            mixed: meeting.audioFileName.map { folder.appendingPathComponent($0) },
            mic: meeting.micTrackFileName.map { folder.appendingPathComponent($0) },
            mac: meeting.macTrackFileName.map { folder.appendingPathComponent($0) }
        )
        let captureSystemAudio = preferences.meetingCaptureSystemAudio
        let voiceProcessing = preferences.meetingVoiceProcessing
        startTask = Task { [weak self] in
            do {
                try await recorder.start(outputs: outputs, captureSystemAudio: captureSystemAudio,
                                         voiceProcessing: voiceProcessing)
                guard let self else { return }
                if !recorder.systemAudioActive { meeting.macTrackFileName = nil }
                self.log.info("Meeting recording: Mac audio \(recorder.systemAudioActive), voice processing \(recorder.voiceProcessingActive)")
                let problems = [recorder.systemAudioError, recorder.voiceProcessingError].compactMap { $0 }
                if !problems.isEmpty {
                    meeting.note = problems.joined(separator: " ")
                    self.save()
                }
                if recorder.systemAudioError != nil {
                    self.onFlash?(.done("Meeting started · mic only"))
                } else if recorder.voiceProcessingError != nil {
                    self.onFlash?(.done("Meeting started · noise reduction off"))
                } else {
                    self.onFlash?(.done("Meeting started"))
                }
            } catch {
                guard let self else { return }
                self.log.error("Meeting recording failed to start: \(error.localizedDescription, privacy: .public)")
                self.onFlash?(.error("Mic error: \(error.localizedDescription)"))
                self.abandon(meeting)
            }
        }

        maxDurationTask?.cancel()
        let maxSeconds = preferences.meetingMaxSeconds
        maxDurationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(maxSeconds))
            guard !Task.isCancelled else { return }
            self?.stop()
        }
        log.info("Meeting started")
    }

    func stop() {
        guard isRecording, let meeting, let recorder else { return }
        isRecording = false
        lastStoppedAt = Date()
        level = 0
        activeMeetingID = nil
        maxDurationTask?.cancel()
        Sounds.play(.stop, enabled: preferences.playSounds)
        onFlash?(.done("Meeting saved · writing notes…"))

        let startTask = self.startTask
        let input = chunkInput
        let transcribing = transcribeTask
        self.meeting = nil
        self.recorder = nil
        self.startTask = nil
        self.chunkInput = nil
        self.transcribeTask = nil

        meeting.state = .transcribing
        save()
        progress[meeting.id] = "Finishing the transcript…"

        Task { [weak self] in
            await startTask?.value
            let duration = await recorder.stop()   // hands over the last piece before returning
            input?.finish()
            await transcribing?.value
            guard let self else { return }
            meeting.duration = duration
            self.save()
            self.log.info("Meeting stopped after \(duration, format: .fixed(precision: 0))s, \(meeting.segments.count) segments")
            await self.cleanUp(meeting)
            if meeting.segments.isEmpty || !self.preferences.meetingWriteNotes {
                if !meeting.segments.isEmpty {
                    meeting.state = .done
                    self.progress[meeting.id] = nil
                    self.save()
                    self.onFlash?(.done("Meeting transcript ready"))
                    return
                }
                meeting.state = .done
                meeting.note = "Nothing was heard in this recording."
                self.progress[meeting.id] = nil
                self.save()
                self.onFlash?(.done("Meeting saved · nothing heard"))
                return
            }
            await self.summarize(meeting)
        }
    }

    func toggle() {
        isRecording ? stop() : start()
    }

    /// Recording never really started (mic error): remove the empty meeting.
    private func abandon(_ meeting: Meeting) {
        guard self.meeting === meeting else { return }
        isRecording = false
        activeMeetingID = nil
        level = 0
        maxDurationTask?.cancel()
        chunkInput?.finish()
        self.meeting = nil
        recorder = nil
        chunkInput = nil
        transcribeTask = nil
        MeetingStorage.deleteAudio(of: meeting)
        context.delete(meeting)
        save()
    }

    private func transcribe(_ samples: [Float], start: Double, model: SpeechModel, language: String?,
                            removeFillers: Bool, into meeting: Meeting) async {
        // Skip silence: Whisper tends to invent words ("Thank you.") when nothing is said.
        guard samples.count >= Int(AudioRecorder.sampleRate * 0.5), AudioRecorder.rms(samples) > 0.003 else { return }
        let started = Date()
        do {
            let raw = try await transcriber.transcribe(samples, model: model, language: language, modelManager: modelManager)
            let text = PostProcessor.clean(raw, removeFillers: removeFillers)
            guard !text.isEmpty else { return }
            let end = start + Double(samples.count) / AudioRecorder.sampleRate
            meeting.segments.append(TranscriptSegment(start: start, end: end, text: text))
            save()
            log.debug("Meeting piece at \(start, format: .fixed(precision: 0))s transcribed in \(Date().timeIntervalSince(started), format: .fixed(precision: 2))s")
        } catch {
            log.error("Meeting transcription failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Notes

    /// Writes (or rewrites) the summary, key points, decisions and to-dos.
    func summarize(_ meeting: Meeting) async {
        guard summaryTasks[meeting.id] == nil else { return }
        // The notes model picked in Settings › Meetings if it's downloaded, else the assistant's.
        let chat = preferences.meetingNotesModel.flatMap { modelManager.isDownloaded($0) ? $0 : nil }
            ?? preferences.chatModel
        let detail = preferences.meetingNotesDetail
        guard modelManager.isDownloaded(chat) else {
            meeting.state = .done
            meeting.note = "Download an AI model in Settings › AI Assistant to get a summary and to-dos for this meeting."
            progress[meeting.id] = nil
            save()
            onFlash?(.done("Meeting transcript saved"))
            return
        }
        meeting.state = .summarizing
        progress[meeting.id] = "Writing summary and to-dos…"
        save()

        let id = meeting.id
        let task = Task { [weak self] in
            guard let self else { return }
            let started = Date()
            do {
                let notes = try await MeetingSummarizer.summarize(
                    transcript: meeting.transcriptForAI, llm: self.llm, model: chat, detail: detail,
                    progress: { [weak self] line in self?.progress[id] = line }
                )
                if meeting.hasDefaultTitle, let title = notes.title { meeting.title = title }
                meeting.summary = notes.summary
                meeting.keyPoints = notes.keyPoints
                meeting.decisions = notes.decisions
                // Keep to-dos added or ticked by hand when notes are rewritten.
                let kept = meeting.actionItems.filter { $0.done }
                meeting.actionItems = kept + notes.actionItems.filter { new in !kept.contains { $0.text == new.text } }
                meeting.summaryModelName = chat.name
                if meeting.note?.hasPrefix("Couldn't write notes") == true || meeting.note?.hasPrefix("Download an AI model") == true {
                    meeting.note = nil
                }
                self.log.info("Meeting notes written in \(Date().timeIntervalSince(started), format: .fixed(precision: 1))s")
                self.onFlash?(.done("Meeting notes ready"))
            } catch {
                if !Task.isCancelled {
                    meeting.note = "Couldn't write notes: \(error.localizedDescription)"
                    self.onFlash?(.error("Meeting notes failed"))
                }
            }
            meeting.state = .done
            self.progress[id] = nil
            self.summaryTasks[id] = nil
            self.save()
        }
        summaryTasks[id] = task
        await task.value
    }

    // MARK: - Clean-up pass

    /// Redoes the transcript from the separate tracks, with speakers. Keeps the live one if it fails.
    private func cleanUp(_ meeting: Meeting) async {
        defer {
            // Tracks are only kept along with the audio (for "Redo Clean-up").
            if !preferences.meetingKeepAudio { MeetingStorage.deleteTracks(of: meeting) }
            save()
        }
        guard preferences.meetingCleanupPass, meeting.hasTracks else { return }
        let id = meeting.id
        meeting.state = .transcribing
        progress[id] = "Cleaning up the transcript…"
        save()

        let dictationModel = preferences.selectedModel
        // The picked clean-up model, if it's downloaded; otherwise the dictation one.
        let picked = preferences.meetingFinalModel.flatMap { modelManager.isDownloaded($0) ? $0 : nil }
        let model = picked ?? dictationModel
        do {
            let result = try await cleanup.run(
                micURL: meeting.micTrackURL, macURL: meeting.macTrackURL,
                options: MeetingCleanup.Options(
                    identifySpeakers: preferences.meetingIdentifySpeakers,
                    expectedSpeakers: preferences.meetingSpeakerCount > 0 ? preferences.meetingSpeakerCount : nil,
                    removeEcho: preferences.meetingRemoveEcho,
                    speechThreshold: preferences.meetingSpeechSensitivity.threshold
                ),
                model: model, language: preferences.meetingLanguageCode, removeFillers: preferences.removeFillers,
                transcriber: transcriber, modelManager: modelManager,
                progress: { [weak self] line in self?.progress[id] = line }
            )
            if !result.segments.isEmpty {
                meeting.segments = result.segments
                // Keep names given earlier (when redoing the clean-up) for ids that still exist.
                var names = result.speakerNames
                for (speaker, name) in meeting.speakerNames where names[speaker] != nil { names[speaker] = name }
                meeting.speakerNames = names
                meeting.transcriptCleaned = true
                meeting.speechModelName = model.name
            }
            if let problem = result.problem { meeting.note = problem }
        } catch {
            if !Task.isCancelled {
                meeting.note = "Couldn't clean up the transcript (\(error.localizedDescription)). The live transcript is kept."
            }
        }
        // A bigger model was loaded for the clean-up: bring the dictation one back.
        if model.id != dictationModel.id {
            Task { [transcriber, modelManager] in
                try? await transcriber?.prepare(model: dictationModel, modelManager: modelManager!)
            }
        }
    }

    /// "Redo Clean-up and Speakers": the transcript again from the kept tracks, then new notes.
    func redoCleanup(_ meeting: Meeting) {
        guard meeting.state == .done, progress[meeting.id] == nil, meeting.hasTracks else { return }
        Task {
            await cleanUp(meeting)
            if meeting.segments.isEmpty {
                meeting.state = .done
                progress[meeting.id] = nil
                save()
                return
            }
            await summarize(meeting)
        }
    }

    func regenerate(_ meeting: Meeting) {
        guard meeting.state == .done, !meeting.segments.isEmpty else { return }
        Task { await summarize(meeting) }
    }

    /// Only finished meetings can be deleted (not while recording or writing notes).
    func canDelete(_ meeting: Meeting) -> Bool {
        meeting.id != activeMeetingID && progress[meeting.id] == nil && meeting.state == .done
    }

    func delete(_ meeting: Meeting) {
        guard canDelete(meeting) else { return }
        MeetingStorage.deleteAudio(of: meeting)
        context.delete(meeting)
        save()
    }

    // MARK: - Helpers

    /// The app quit (or crashed) during a meeting: keep what was transcribed and mark it finished.
    private func recoverInterruptedMeetings() {
        let all = (try? context.fetch(FetchDescriptor<Meeting>())) ?? []
        for meeting in all where meeting.state != .done {
            meeting.state = .done
            if let last = meeting.segments.last { meeting.duration = max(meeting.duration, last.end) }
            meeting.note = "The recording was interrupted (AK Assistant quit). What was transcribed is kept."
        }
        save()
    }

    private func save() {
        do {
            try context.save()
        } catch {
            log.error("Saving meetings failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
