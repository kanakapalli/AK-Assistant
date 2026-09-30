import AppKit
import SwiftData
import Observation
import os

enum DictationStatus: Equatable {
    case idle
    case recording
    case transcribing      // dictation: turning speech into text; assistant: understanding + thinking
    case done(String)      // short message, e.g. "Pasted" or "Copied"
    case error(String)
}

/// The question you asked the AI and its (possibly still streaming) answer, shown in the answer panel.
struct AssistantReply: Equatable {
    var question: String
    var answer: String = ""
    var isStreaming = true
    var error: String?
}

/// The latest dictation, shown as a transcript card in the floating popup.
struct DictationResult: Equatable {
    var text: String
    var pasted: Bool
    var appName: String?
}

/// Owns both pipelines:
/// - Dictation: hotkey -> recorder -> speech-to-text -> post-process -> paste -> history.
/// - Assistant: hotkey -> recorder -> speech-to-text -> local AI -> answer panel / voice -> history.
/// Views read `status`, `level`, `reply` and `isSpeaking`; with `@Observable` only the views that read them redraw.
@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    let preferences = Preferences()
    let modelManager = ModelManager()
    let container: ModelContainer

    private(set) var status: DictationStatus = .idle
    private(set) var level: Float = 0
    /// Which hotkey started the current recording.
    private(set) var currentAction: HotkeyAction = .dictate
    /// The latest AI question and answer.
    private(set) var reply: AssistantReply?
    private(set) var isSpeaking = false
    /// The latest dictation's transcript, while its card is showing.
    private(set) var dictation: DictationResult?
    /// When the current recording started (for the timer in the popup).
    private(set) var recordingStartedAt: Date?
    /// The pointer is over the popup; the transcript card stays open meanwhile.
    private(set) var isHoveringIsland = false

    // Internal plumbing: not UI state, so SwiftUI doesn't need to track it.
    private let recorder = AudioRecorder()
    private let hotkeys = HotkeyManager()
    private let transcriber = TranscriptionService()
    private let llm = LLMService()
    private let speech = SpeechService()
    private let island = IslandController()
    @ObservationIgnored private var targetApp: NSRunningApplication?
    @ObservationIgnored private var maxDurationTask: Task<Void, Never>?
    @ObservationIgnored private var assistantTask: Task<Void, Never>?
    @ObservationIgnored private var dictationDismissTask: Task<Void, Never>?
    @ObservationIgnored private var started = false
    /// Timings for each step show in Console.app / Xcode under category "Pipeline".
    private let log = Logger(subsystem: "com.natfirst.akassistant", category: "Pipeline")

    /// Hard stop so a stuck key doesn't record forever.
    private let maxRecordingSeconds: Double = 120

    private init() {
        do {
            container = try ModelContainer(for: DictationRecord.self)
        } catch {
            fatalError("Could not open history store: \(error)")
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true

        recorder.onLevel = { [weak self] value in
            Task { @MainActor in self?.level = value }
        }
        hotkeys.onPress = { [weak self] action in self?.beginRecording(action) }
        hotkeys.onRelease = { [weak self] action in self?.endRecording(action) }
        hotkeys.onCancel = { [weak self] in self?.cancelRecording() }
        configureHotkeys()
        transcriber.useNeuralEngine = preferences.useNeuralEngine
        speech.onFinished = { [weak self] in self?.isSpeaking = false }
        island.attach(self)

        observePreferences()
        watchAccessibility()

        HistoryPruner.prune(context: container.mainContext, retentionDays: preferences.historyRetentionDays)

        // Load the models in the background so the first question after launch isn't slow.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            await self?.warmUpModels()
        }
    }

    /// Loads speech-to-text, the chat model and the voice one after another (not all at once,
    /// which would spike memory and make each load slower). Missing models are skipped.
    private func warmUpModels() async {
        let p = preferences
        let started = Date()
        if modelManager.isDownloaded(p.selectedModel) {
            try? await transcriber.prepare(model: p.selectedModel, modelManager: modelManager)
        }
        if modelManager.isDownloaded(p.chatModel) {
            try? await llm.prepare(p.chatModel)
            if p.replyStyle.speaks, let folder = modelManager.localFolder(for: p.voiceModel) {
                try? await speech.prepare(variant: p.voiceModel.id, folder: folder, voice: p.voice, languageCode: p.languageCode)
            }
        }
        log.info("Models warmed up in \(Date().timeIntervalSince(started), format: .fixed(precision: 1))s")
    }

    private func configureHotkeys() {
        hotkeys.configure(dictate: preferences.hotkey, assistant: preferences.assistantHotkey)
    }

    /// Reacts when hotkeys or models change anywhere in the UI (Settings, Onboarding, Models).
    /// `withObservationTracking` fires once per change, so it re-registers itself each time.
    private func observePreferences() {
        let hotkey = preferences.hotkey
        let assistantHotkey = preferences.assistantHotkey
        let modelID = preferences.selectedModelID
        let neuralEngine = preferences.useNeuralEngine
        let chatModelID = preferences.chatModelID
        let voiceModelID = preferences.voiceModelID
        withObservationTracking {
            _ = preferences.hotkey
            _ = preferences.assistantHotkey
            _ = preferences.selectedModelID
            _ = preferences.useNeuralEngine
            _ = preferences.chatModelID
            _ = preferences.voiceModelID
        } onChange: { [weak self] in
            // onChange runs just before the new value is stored, so hop to the next main-actor turn to read it.
            Task { @MainActor in
                guard let self else { return }
                let p = self.preferences
                if p.hotkey != hotkey || p.assistantHotkey != assistantHotkey { self.configureHotkeys() }
                if p.selectedModelID != modelID { self.transcriber.unload() }
                if p.useNeuralEngine != neuralEngine {
                    self.transcriber.useNeuralEngine = p.useNeuralEngine
                    self.transcriber.unload()
                }
                if p.chatModelID != chatModelID { self.llm.unload() }
                if p.voiceModelID != voiceModelID { self.speech.unload() }
                self.observePreferences()
            }
        }
    }

    /// Global key monitors only deliver events once Accessibility is granted; re-arm them when it flips on.
    private func watchAccessibility() {
        Task { [weak self] in
            var wasTrusted = Permissions.accessibilityGranted
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                let trusted = Permissions.accessibilityGranted
                if trusted && !wasTrusted { self.configureHotkeys() }
                wasTrusted = trusted
            }
        }
    }

    var menuBarSymbol: String {
        switch status {
        case .recording: return currentAction == .assistant ? "sparkles" : "waveform.circle.fill"
        case .transcribing: return "ellipsis.circle"
        default: return isSpeaking ? "speaker.wave.2.fill" : "waveform"
        }
    }

    /// What the floating popup shows. The popup follows this by itself (see IslandController).
    var islandMode: IslandMode {
        switch status {
        case .recording, .transcribing, .done, .error: return .compact   // short messages win for a moment
        case .idle: break
        }
        if dictation != nil { return .dictation }
        if reply != nil, preferences.replyStyle.shows { return .answer }
        return isSpeaking ? .compact : .hidden
    }

    var isBusy: Bool {
        status == .recording || status == .transcribing
    }

    // MARK: - Recording (shared by both hotkeys)

    func beginRecording(_ action: HotkeyAction) {
        guard !isBusy else { return }

        let model = preferences.selectedModel
        guard modelManager.isDownloaded(model) else {
            flash(.error("Download \(model.name) first"))
            return
        }
        if action == .assistant {
            let chat = preferences.chatModel
            guard modelManager.isDownloaded(chat) else {
                flash(.error("Download \(chat.name) first"))
                return
            }
        }
        guard Permissions.microphoneGranted else {
            flash(.error("Microphone access needed"))
            return
        }

        // Talking over an answer: stop the voice so the mic hears only you.
        if isSpeaking { stopSpeaking() }

        currentAction = action
        targetApp = NSWorkspace.shared.frontmostApplication
        dismissDictation()
        do {
            try recorder.start()
        } catch {
            flash(.error("Mic error: \(error.localizedDescription)"))
            return
        }

        status = .recording
        recordingStartedAt = Date()
        hotkeys.recordingActive = true
        Sounds.play(.start, enabled: preferences.playSounds)

        // Load models while the user is still talking.
        Task { [transcriber, modelManager] in
            try? await transcriber.prepare(model: model, modelManager: modelManager)
        }
        if action == .assistant { preloadAssistant() }

        maxDurationTask?.cancel()
        maxDurationTask = Task { [weak self, maxRecordingSeconds] in
            try? await Task.sleep(for: .seconds(maxRecordingSeconds))
            guard !Task.isCancelled, let self else { return }
            self.endRecording(self.currentAction)
        }
    }

    func cancelRecording() {
        guard status == .recording else { return }
        maxDurationTask?.cancel()
        _ = recorder.stop()
        hotkeys.recordingActive = false
        flash(.done("Cancelled"))
    }

    func endRecording(_ action: HotkeyAction) {
        guard status == .recording, action == currentAction else { return }
        maxDurationTask?.cancel()
        hotkeys.recordingActive = false

        let samples = recorder.stop()
        let duration = Double(samples.count) / AudioRecorder.sampleRate

        // Ignore taps and silence (Whisper tends to hallucinate on silence).
        guard duration >= 0.3, AudioRecorder.rms(samples) > 0.004 else {
            status = .idle
            return
        }

        status = .transcribing
        Sounds.play(.stop, enabled: preferences.playSounds)

        let model = preferences.selectedModel
        let language = preferences.languageCode
        let removeFillers = preferences.removeFillers

        Task {
            do {
                let sttStarted = Date()
                let raw = try await transcriber.transcribe(samples, model: model, language: language, modelManager: modelManager)
                log.info("Speech-to-text: \(Date().timeIntervalSince(sttStarted), format: .fixed(precision: 2))s for \(duration, format: .fixed(precision: 1))s of audio")
                let text = PostProcessor.clean(raw, removeFillers: removeFillers)
                guard !text.isEmpty else {
                    flash(.done("Nothing heard"))
                    return
                }
                switch action {
                case .dictate: await paste(text, duration: duration, model: model)
                case .assistant: ask(text, duration: duration)
                }
            } catch {
                flash(.error("Transcription failed"))
                NSLog("AK Assistant transcription error: \(error)")
            }
        }
    }

    // MARK: - Dictation

    private func paste(_ text: String, duration: Double, model: SpeechModel) async {
        let app = targetApp
        // Make sure the original app is still in front before pasting.
        if let app, app != NSWorkspace.shared.frontmostApplication {
            app.activate()
            try? await Task.sleep(for: .milliseconds(120))
        }
        let result = TextInserter.insert(text, restoreClipboard: preferences.restoreClipboard)
        saveHistory(DictationRecord(
            text: text, duration: duration, modelName: model.name,
            appName: app?.localizedName, appBundleID: app?.bundleIdentifier
        ))
        // Show what was typed in the popup; it closes by itself after a few seconds.
        status = .idle
        dictation = DictationResult(text: text, pasted: result == .pasted, appName: app?.localizedName)
        scheduleDictationDismiss()
    }

    /// Longer transcripts stay up longer so there's time to read them (4–15 s).
    private func scheduleDictationDismiss(after delay: Double? = nil) {
        dictationDismissTask?.cancel()
        guard let dictation else { return }
        let words = Double(dictation.text.split(whereSeparator: \.isWhitespace).count)
        let seconds = delay ?? min(15, max(4, 2 + words * 0.25))
        dictationDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, !self.isHoveringIsland else { return }
            self.dictation = nil
        }
    }

    func dismissDictation() {
        dictationDismissTask?.cancel()
        dictation = nil
    }

    func copyDictation() {
        guard let text = dictation?.text else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Hovering keeps the transcript card open; leaving closes it shortly after.
    func setIslandHovering(_ hovering: Bool) {
        guard hovering != isHoveringIsland else { return }
        isHoveringIsland = hovering
        if hovering {
            dictationDismissTask?.cancel()
        } else if dictation != nil {
            scheduleDictationDismiss(after: 2.5)
        }
    }

    // MARK: - AI assistant

    /// Starts loading the chat model (and the voice) as soon as the AI hotkey goes down.
    /// Both are usually already loaded (see `warmUpModels`); this covers the case where they were unloaded.
    private func preloadAssistant() {
        let chat = preferences.chatModel
        Task { [llm] in try? await llm.prepare(chat) }
        if preferences.replyStyle.speaks, let folder = modelManager.localFolder(for: preferences.voiceModel) {
            let variant = preferences.voiceModel.id
            let voice = preferences.voice
            let language = preferences.languageCode
            Task { [speech] in try? await speech.prepare(variant: variant, folder: folder, voice: voice, languageCode: language) }
        }
    }

    private func ask(_ question: String, duration: Double) {
        let style = preferences.replyStyle
        let chat = preferences.chatModel
        reply = AssistantReply(question: question)
        if style.shows {
            status = .idle           // the popup turns into the answer card
        } else {
            status = .transcribing   // pill keeps saying "Thinking…"
        }

        // Open the voice now, so each sentence is spoken as soon as the AI has written it
        // instead of waiting for the whole answer.
        let speaking = style.speaks && beginSpeaking()
        let askedAt = Date()

        assistantTask?.cancel()
        assistantTask = Task {
            do {
                let stream = try await llm.ask(question, model: chat)
                var raw = ""
                var splitter = SentenceSplitter()
                var gotFirstToken = false
                var announced = false
                for try await chunk in stream {
                    if Task.isCancelled { break }
                    if !gotFirstToken {
                        gotFirstToken = true
                        log.info("AI first words after \(Date().timeIntervalSince(askedAt), format: .fixed(precision: 2))s")
                    }
                    raw += chunk
                    let shown = AnswerCleaner.forDisplay(raw)
                    reply?.answer = shown
                    guard speaking else { continue }
                    for sentence in splitter.take(from: shown) {
                        speech.enqueue(AnswerCleaner.forSpeech(sentence))
                        if !announced {
                            announced = true
                            log.info("First sentence sent to voice after \(Date().timeIntervalSince(askedAt), format: .fixed(precision: 2))s")
                            if !style.shows { flash(.done("Answering…")) }
                        }
                    }
                }
                let answer = AnswerCleaner.forDisplay(raw)
                let record = DictationRecord(
                    text: question, duration: duration, modelName: chat.name,
                    appName: nil, appBundleID: nil, kind: "assistant", answer: answer
                )
                // Closed or replaced by a newer question: keep the history, but don't touch
                // the new question's panel or voice.
                if Task.isCancelled {
                    if !answer.isEmpty { saveHistory(record) }
                    return
                }
                reply?.answer = answer
                reply?.isStreaming = false
                log.info("AI answer complete after \(Date().timeIntervalSince(askedAt), format: .fixed(precision: 2))s")
                if speaking {
                    speech.enqueue(AnswerCleaner.forSpeech(splitter.remainder(of: answer)))
                    speech.finish()
                }
                if !style.shows && !announced { flash(.done("Answering…")) }
                saveHistory(record)
            } catch {
                if Task.isCancelled { return }   // a newer question took over
                if speaking { stopSpeaking() }
                reply?.isStreaming = false
                reply?.error = "The AI couldn't answer: \(error.localizedDescription)"
                if !style.shows { flash(.error("AI error")) }
                NSLog("AK Assistant AI error: \(error)")
            }
        }
    }

    /// Opens the voice for a new answer. Returns false if no voice model is downloaded.
    private func beginSpeaking() -> Bool {
        let voiceModel = preferences.voiceModel
        guard let folder = modelManager.localFolder(for: voiceModel) else {
            if reply != nil, reply?.error == nil {
                reply?.error = "Download a voice in Models to hear answers aloud."
            }
            return false
        }
        isSpeaking = true
        speech.begin(variant: voiceModel.id, folder: folder, voice: preferences.voice, languageCode: preferences.languageCode)
        return true
    }

    /// Reads a complete answer aloud if a voice model is downloaded.
    func speak(_ answer: String) {
        guard beginSpeaking() else { return }
        speech.enqueue(AnswerCleaner.forSpeech(answer))
        speech.finish()
    }

    func speakAgain() {
        guard let answer = reply?.answer, !answer.isEmpty else { return }
        speak(answer)
    }

    func stopSpeaking() {
        speech.stop()
        isSpeaking = false
    }

    func copyAnswer() {
        guard let answer = reply?.answer, !answer.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(answer, forType: .string)
    }

    /// Forget earlier questions so the next one starts a fresh conversation.
    func newConversation() {
        llm.newConversation()
        closeAnswer()
    }

    func closeAnswer() {
        assistantTask?.cancel()
        stopSpeaking()
        reply = nil
    }

    // MARK: - Helpers

    private func flash(_ newStatus: DictationStatus) {
        status = newStatus
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard let self else { return }
            if case .recording = self.status { return }
            if case .transcribing = self.status { return }
            self.status = .idle
        }
    }

    private func saveHistory(_ record: DictationRecord) {
        guard preferences.historyRetentionDays >= 0 else { return }
        container.mainContext.insert(record)
        try? container.mainContext.save()
    }

    // MARK: - Model warm-up (used by onboarding)

    func warmUpSelectedModel() async throws {
        try await transcriber.prepare(model: preferences.selectedModel, modelManager: modelManager)
    }
}
