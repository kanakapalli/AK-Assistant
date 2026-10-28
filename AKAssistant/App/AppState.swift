import AppKit
import SwiftData
import Observation
import KeyboardShortcuts
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
    /// Set when the AI hotkey ran (or is about to run) a Mac command instead of chatting.
    var command: CommandBadge? = nil
    /// “Did you mean…”: commands close in meaning to what was said, shown as Try buttons.
    var suggestions: [String] = []
}

/// The Mac command shown on the answer card.
struct CommandBadge: Equatable {
    var title: String
    var symbol: String
    /// Waiting for Run / Cancel ("Ask before risky actions" in Settings).
    var needsConfirmation = false
}

/// The latest dictation, shown as a transcript card in the floating popup.
struct DictationResult: Equatable {
    var text: String
    var pasted: Bool
    var appName: String?
    /// Set when the text was only copied, so the card can say why and how to fix it.
    var copyReason: TextInserter.CopyReason? = nil
    /// ⌘V was sent but the app didn't report a focused field, so it may not have landed.
    var unconfirmed = false
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
    /// Meeting mode: double-tap the dictation key to record, transcribe and summarise a meeting.
    let meetings = MeetingCoordinator()
    /// Smart search & memory: EmbeddingGemma, the search index, meaning-based command matching.
    let memory = MemoryCenter()

    private(set) var status: DictationStatus = .idle {
        didSet {
            // Remember when a long step started, so a stuck one can be recovered (see beginRecording).
            switch status {
            case .recording, .transcribing:
                if busySince == nil { busySince = Date() }
            default:
                busySince = nil
            }
        }
    }
    @ObservationIgnored private var busySince: Date?
    private(set) var level: Float = 0
    /// Which hotkey started the current recording.
    private(set) var currentAction: HotkeyAction = .dictate
    /// The latest AI question and answer.
    private(set) var reply: AssistantReply?
    private(set) var isSpeaking = false
    /// The latest dictation's transcript, while its card is showing.
    private(set) var dictation: DictationResult?
    /// Rough transcript shown in the popup while you're still talking (the final one replaces it).
    private(set) var liveTranscript = ""
    /// When the current recording started (for the timer in the popup).
    private(set) var recordingStartedAt: Date?
    /// The pointer is over the popup; the transcript card stays open meanwhile.
    private(set) var isHoveringIsland = false
    /// Which page the main window shows (the menu bar's "Learn" item switches it).
    var sidebarSelection: SidebarItem? = .history
    /// Which page Settings shows (Learn and Meetings open it on the matching page).
    var settingsTab: SettingsTab = .dictation
    /// A feature to scroll to and highlight when Settings › Models opens (from a "Change…" link).
    var modelsFocus: ModelFeature?
    /// Timers and reminders set by voice.
    var timers: TimerCenter { commands.timers }
    /// The last Mac command that ran, with when (Learn's "Get started" checks this off).
    private(set) var lastCommand: (title: String, at: Date)?
    /// A writing tool is copying, rewriting or pasting: what the popup says ("Write as email…").
    private(set) var rewriteLabel: String?
    /// When a writing tool last pasted its result (Learn's "Get started" checks this off).
    private(set) var lastRewriteAt: Date?

    // Internal plumbing: not UI state, so SwiftUI doesn't need to track it.
    private let recorder = AudioRecorder()
    /// Identifies the current recording, so a late microphone error can't affect a newer one.
    @ObservationIgnored private var recordingToken: UUID?
    /// Mutes the Mac's speakers while a hotkey is held (Settings › Transcription).
    private let silencer = SystemAudioSilencer()
    private let hotkeys = HotkeyManager()
    private let transcriber = TranscriptionService()
    private let llm = LLMService()
    private let speech = SpeechService()
    private let island = IslandController()
    private let commands = CommandRunner()
    @ObservationIgnored private var commandTask: Task<Void, Never>?
    @ObservationIgnored private var grammarTask: Task<Void, Never>?
    /// Writing tools whose shortcut handler is installed (each is installed once).
    @ObservationIgnored private var registeredTextActions: Set<String> = []
    /// A risky command waiting for Run / Cancel.
    @ObservationIgnored private var pendingCommand: (command: MacCommand, question: String, duration: Double)?
    @ObservationIgnored private var targetApp: NSRunningApplication?
    @ObservationIgnored private var maxDurationTask: Task<Void, Never>?
    @ObservationIgnored private var assistantTask: Task<Void, Never>?
    @ObservationIgnored private var islandCloseTask: Task<Void, Never>?
    @ObservationIgnored private var livePreviewTask: Task<Void, Never>?
    /// Streaming models: feeds audio to the model while you talk and returns the final text.
    @ObservationIgnored private var streamTask: Task<String?, Never>?
    @ObservationIgnored private var streamInput: AsyncStream<[Float]>.Continuation?
    @ObservationIgnored private var started = false
    /// Timings for each step show in Console.app / Xcode under category "Pipeline".
    private let log = Logger(subsystem: "com.natfirst.akassistant", category: "Pipeline")

    /// Hard stop so a stuck key doesn't record forever.
    private let maxRecordingSeconds: Double = 120

    private init() {
        do {
            // Meetings live in their own file inside Duck Keyboard's folder. SwiftData's default file
            // (~/Library/Application Support/default.store) is shared by every non-sandboxed app that
            // uses the defaults, including older Duck Keyboard copies: one without meetings migrates the
            // file back to its own layout and the meetings table is dropped.
            // History stays in the default file so existing dictations are kept.
            Self.moveMeetingsToOwnStore()
            let history = ModelConfiguration(schema: Schema([DictationRecord.self]))
            let meetings = ModelConfiguration("Meetings", schema: Schema([Meeting.self]), url: MeetingStorage.storeURL)
            container = try ModelContainer(for: DictationRecord.self, Meeting.self, configurations: history, meetings)
        } catch {
            fatalError("Could not open history store: \(error)")
        }
        // Speech models were replaced (Parakeet instead of most Whisper models): move anyone on a
        // retired model to the new default and start downloading it in the background.
        if ModelCatalog.model(id: preferences.selectedModelID) == nil {
            let replacement = ModelCatalog.defaultModel
            preferences.selectedModelID = replacement.id
            if preferences.onboarded, !modelManager.isDownloaded(replacement) {
                Task { [modelManager] in await modelManager.download(replacement) }
            }
        }
        // One-time switch from Whisper (the old default) to Parakeet, which is several times faster,
        // for anyone dictating in a language Parakeet covers. Hindi and other Indian languages stay on Whisper.
        let parakeetLanguages: Set<String> = ["auto", "en", "es", "fr", "de"]
        if !UserDefaults.standard.bool(forKey: "migratedToParakeet"), ModelCatalog.model(id: preferences.selectedModelID)?.engine == .whisperKit,
           parakeetLanguages.contains(preferences.language) {
            let replacement = ModelCatalog.defaultModel
            preferences.selectedModelID = replacement.id
            if preferences.onboarded, !modelManager.isDownloaded(replacement) {
                Task { [modelManager] in await modelManager.download(replacement) }
            }
        }
        UserDefaults.standard.set(true, forKey: "migratedToParakeet")

        // Until Learn has been seen, the main window opens on it.
        if !preferences.seenLearn { sidebarSelection = .learn }

        // Already set up (e.g. the window was closed on the last onboarding step): don't show
        // onboarding again. Done here, before the window decides whether to open at launch.
        if !preferences.onboarded, Permissions.microphoneGranted, Permissions.accessibilityGranted,
           modelManager.isDownloaded(preferences.selectedModel) {
            preferences.onboarded = true
        }

        meetings.attach(preferences: preferences, modelManager: modelManager, transcriber: transcriber,
                        llm: llm, container: container)
        memory.attach(appContainer: container, preferences: preferences) { [weak self] in
            self?.memoryShouldPause ?? true
        }
    }

    /// The indexer waits while you dictate, ask, listen to an answer or record a meeting.
    private var memoryShouldPause: Bool {
        isBusy || meetings.isRecording || isSpeaking || reply?.isStreaming == true
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true

        recorder.onLevel = { [weak self] value in
            Task { @MainActor in self?.level = value }
        }
        hotkeys.onPress = { [weak self] action in self?.hotkeyPressed(action) }
        hotkeys.onDoubleTap = { [weak self] action in self?.hotkeyDoubleTapped(action) }
        meetings.onFlash = { [weak self] status in self?.flash(status) }
        hotkeys.onRelease = { [weak self] action in self?.endRecording(action) }
        hotkeys.onCancel = { [weak self] in self?.cancelRecording() }
        configureHotkeys()
        speech.onFinished = { [weak self] in self?.isSpeaking = false }
        commands.timers.onFire = { [weak self] timer in self?.timerFired(timer) }
        island.attach(self)
        watchIslandAutoClose()

        if preferences.onboarded {
            flash(.done("Duck Keyboard is ready"))   // quiet launch: a brief sign it's running
        }
        // Two copies (e.g. an older one in Applications that starts at login) both react to the
        // same keys and fight over the microphone.
        if !Self.otherCopiesRunning.isEmpty {
            log.error("Another copy of Duck Keyboard is running: \(Self.otherCopiesRunning.map(\.path).joined(separator: ", "), privacy: .public)")
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                self?.flash(.error("Another copy of Duck Keyboard is running · quit it"))
            }
        }

        observePreferences()
        watchAccessibility()
        log.info("Permissions at launch: \(Permissions.summary, privacy: .public)")

        HistoryPruner.prune(context: container.mainContext, retentionDays: preferences.historyRetentionDays)

        // Load the models in the background so the first question after launch isn't slow.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            await self?.warmUpModels()
            // Then the search index (off unless turned on in Settings › Search & memory).
            self?.memory.start()
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
        hotkeys.doubleTapActions = preferences.meetingDoubleTap ? [.dictate] : []
        configureTextActions()
    }

    /// Reacts when hotkeys or models change anywhere in the UI (Settings, Onboarding, Models).
    /// `withObservationTracking` fires once per change, so it re-registers itself each time.
    private func observePreferences() {
        let hotkey = preferences.hotkey
        let assistantHotkey = preferences.assistantHotkey
        let modelID = preferences.selectedModelID
        let chatModelID = preferences.chatModelID
        let voiceModelID = preferences.voiceModelID
        let meetingDoubleTap = preferences.meetingDoubleTap
        let grammarFixEnabled = preferences.grammarFixEnabled
        let textActionStates = preferences.textActions.map { "\($0.id):\($0.enabled)" }
        withObservationTracking {
            _ = preferences.meetingDoubleTap
            _ = preferences.grammarFixEnabled
            _ = preferences.textActions
            _ = preferences.hotkey
            _ = preferences.assistantHotkey
            _ = preferences.selectedModelID
            _ = preferences.chatModelID
            _ = preferences.voiceModelID
        } onChange: { [weak self] in
            // onChange runs just before the new value is stored, so hop to the next main-actor turn to read it.
            Task { @MainActor in
                guard let self else { return }
                let p = self.preferences
                if p.hotkey != hotkey || p.assistantHotkey != assistantHotkey || p.meetingDoubleTap != meetingDoubleTap
                    || p.grammarFixEnabled != grammarFixEnabled
                    || p.textActions.map({ "\($0.id):\($0.enabled)" }) != textActionStates {
                    self.configureHotkeys()
                }
                if p.selectedModelID != modelID { self.transcriber.unload() }
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
        if meetings.isRecording { return "record.circle" }
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
        if meetings.isRecording { return .compact }   // small "Meeting 12:34" capsule
        if dictation != nil { return .dictation }
        if reply != nil, preferences.replyStyle.shows || reply?.command?.needsConfirmation == true
            || reply?.suggestions.isEmpty == false { return .answer }
        return isSpeaking ? .compact : .hidden
    }

    var isBusy: Bool {
        status == .recording || status == .transcribing
    }

    // MARK: - Meetings

    /// During a meeting, a press of the dictation key stops it; otherwise keys work as usual.
    private func hotkeyPressed(_ action: HotkeyAction) {
        log.info("Key down: \(action.rawValue, privacy: .public) · status \(String(describing: self.status), privacy: .public) · meeting \(self.meetings.isRecording)")
        guard meetings.isRecording else {
            beginRecording(action)
            return
        }
        if action == .dictate {
            stopMeeting()
        } else {
            flash(.error("Recording a meeting · press \(preferences.hotkey.title) to stop"))
        }
    }

    private func hotkeyDoubleTapped(_ action: HotkeyAction) {
        guard action == .dictate, preferences.meetingDoubleTap else { return }
        if meetings.isRecording {
            stopMeeting()
            return
        }
        // The second tap of a "press again or double-tap" stop: don't start a new meeting.
        if let stopped = meetings.lastStoppedAt, Date().timeIntervalSince(stopped) < 1.0 { return }
        startMeeting()
    }

    func startMeeting() {
        guard !meetings.isRecording else { return }
        if status == .recording { cancelRecording() }   // the first tap started a dictation
        guard !isBusy else {
            flash(.error("Busy · try again in a moment"))
            return
        }
        if isSpeaking { stopSpeaking() }
        dismissDictation()
        meetings.start()
    }

    func stopMeeting() {
        meetings.stop()
    }

    /// Copies of Duck Keyboard other than this one that are running right now.
    static var otherCopiesRunning: [URL] {
        guard let id = Bundle.main.bundleIdentifier else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0.processIdentifier != me }
            .compactMap(\.bundleURL)
    }

    /// For Settings › Hotkey check.
    var hotkeyDiagnostics: (lastEvent: String?, lastEventAt: Date?, keysDown: String, monitors: Int) {
        let down = hotkeys.isDown.map(\.rawValue).sorted().joined(separator: ", ")
        return (hotkeys.lastEvent?.text, hotkeys.lastEvent?.at, down.isEmpty ? "none" : down, hotkeys.monitorCount)
    }

    /// Settings › Hotkey check › Reset: forget key state, re-install monitors, clear a stuck step.
    /// Gives the Mac its sound back (used when quitting mid-dictation).
    func restoreSystemAudio() {
        silencer.restore()
    }

    func resetHotkeys() {
        hotkeys.reset()
        if isBusy { recoverFromStuckState() }
        flash(.done("Hotkeys reset"))
    }

    private func recoverFromStuckState() {
        _ = stopLivePreview()
        stopStreaming()?.cancel()
        maxDurationTask?.cancel()
        _ = recorder.stop()   // safe if it isn't recording
        silencer.restore()
        assistantTask?.cancel()
        commandTask?.cancel()
        grammarTask?.cancel()
        rewriteLabel = nil
        hotkeys.recordingActive = false
        status = .idle
    }

    /// Opens Settings on one of its pages.
    func openSettings(_ tab: SettingsTab) {
        settingsTab = tab
        sidebarSelection = .settings
    }

    /// Opens the main window on Meetings (from the menu bar).
    func showMeetings() {
        sidebarSelection = .meetings
    }

    // MARK: - Recording (shared by both hotkeys)

    func beginRecording(_ action: HotkeyAction) {
        // A step that has been "busy" far longer than any real one can take is stuck (a task that
        // never finished). Recover instead of ignoring the key forever.
        if isBusy, let since = busySince, Date().timeIntervalSince(since) > maxRecordingSeconds + 60 {
            log.error("Recovering from a stuck \(String(describing: self.status), privacy: .public) state")
            recoverFromStuckState()
        }
        guard !isBusy else {
            log.info("Key ignored: still \(String(describing: self.status), privacy: .public)")
            return
        }
        guard !meetings.isRecording else { return }

        let model = preferences.selectedModel
        guard modelManager.isDownloaded(model) else {
            if case .downloading = modelManager.state(of: model) {
                flash(.error("\(model.name) is still downloading…"))
            } else {
                flash(.error("Download \(model.name) first"))
            }
            return
        }
        if action == .assistant {
            let chat = preferences.chatModel
            // Mac commands work without the chat model; questions check for it later.
            guard modelManager.isDownloaded(chat) || preferences.macCommandsEnabled else {
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
        // Streaming models get the audio as it's recorded, so hook them up before recording starts.
        if model.supportsStreaming { startStreaming(model: model) }
        // Silence videos and music before the microphone opens, so none of it gets recorded.
        if preferences.muteWhileDictating { silencer.silence() }
        // The mic starts on a background queue, so the popup appears the instant the key goes down
        // instead of waiting for the audio hardware.
        recorder.echoCancellation = preferences.cancelSpeakerEcho
        let token = UUID()
        recordingToken = token
        recorder.startInBackground { [weak self] error in
            guard let error else { return }
            Task { @MainActor in self?.microphoneFailed(error, token: token) }
        }

        status = .recording
        liveTranscript = ""
        recordingStartedAt = Date()
        hotkeys.recordingActive = true
        Sounds.play(.start, enabled: preferences.playSounds)

        // Load models while the user is still talking.
        Task { [transcriber, modelManager] in
            try? await transcriber.prepare(model: model, modelManager: modelManager)
        }
        if action == .assistant { preloadAssistant() }
        // Models that can't stream re-read the recent audio for the live preview instead.
        if preferences.showLiveTranscript && !model.supportsStreaming { startLivePreview(model: model) }

        maxDurationTask?.cancel()
        maxDurationTask = Task { [weak self, maxRecordingSeconds] in
            try? await Task.sleep(for: .seconds(maxRecordingSeconds))
            guard !Task.isCancelled, let self else { return }
            self.endRecording(self.currentAction)
        }
    }

    /// The microphone couldn't start (it runs in the background, so this arrives just after the key press).
    private func microphoneFailed(_ error: Error, token: UUID) {
        guard recordingToken == token, status == .recording else { return }
        _ = stopLivePreview()
        stopStreaming()?.cancel()
        maxDurationTask?.cancel()
        silencer.restore()
        hotkeys.recordingActive = false
        flash(.error("Mic error: \(error.localizedDescription)"))
    }

    /// While you talk, re-transcribes the recent audio about once a second and shows it in the popup.
    /// It's a rough preview; when you let go, the whole recording is transcribed again for the final text.
    private func startLivePreview(model: SpeechModel) {
        livePreviewTask?.cancel()
        let language = preferences.languageCode
        let removeFillers = preferences.removeFillers
        // Parakeet is fast enough to re-read the recent audio several times a second. Whisper always
        // processes a padded 30 s window, so each pass costs the same however short the clip is.
        let isWhisper = model.engine == .whisperKit
        let window: Double = isWhisper ? 30 : 20     // older speech scrolls off as "…"
        // Not too often: every preview pass keeps the GPU busy, and the final pass has to wait for it.
        let pause: Duration = isWhisper ? .milliseconds(600) : .milliseconds(250)
        livePreviewTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            var lastLength = 0.0
            while !Task.isCancelled {
                guard let self, self.status == .recording else { return }
                let total = self.recorder.recordedSeconds
                // Nothing new said since the last pass: wait a moment instead of redoing the same audio.
                if total - lastLength < 0.15 {
                    try? await Task.sleep(for: .milliseconds(60))
                    continue
                }
                lastLength = total
                let audio = self.recorder.snapshot(lastSeconds: window)
                // Skip near-silence: Whisper tends to invent words ("Thank you.") when nothing is said.
                if audio.count >= Int(AudioRecorder.sampleRate * 0.5), AudioRecorder.rms(audio) > 0.004 {
                    let started = Date()
                    if let raw = try? await self.transcriber.transcribe(audio, model: model, language: language, modelManager: self.modelManager) {
                        guard !Task.isCancelled, self.status == .recording else { return }
                        let text = PostProcessor.clean(raw, removeFillers: removeFillers)
                        if !text.isEmpty { self.liveTranscript = (total > window ? "… " : "") + text }
                        self.log.debug("Live preview pass: \(Date().timeIntervalSince(started), format: .fixed(precision: 2))s for \(Double(audio.count) / AudioRecorder.sampleRate, format: .fixed(precision: 1))s of audio")
                    }
                }
                try? await Task.sleep(for: pause)
            }
        }
    }

    /// Streams the recording into the model while you talk: the live text comes from the model's
    /// running transcript, and when you let go only the last fraction of a second is left to process.
    private func startStreaming(model: SpeechModel) {
        _ = stopStreaming()?.cancel()
        let (stream, input) = AsyncStream<[Float]>.makeStream()
        streamInput = input
        recorder.onSamples = { input.yield($0) }   // audio thread; the continuation is thread-safe
        let showLive = preferences.showLiveTranscript
        let removeFillers = preferences.removeFillers
        let log = log
        streamTask = Task { [weak self, transcriber, modelManager] in
            do {
                // Audio recorded while the model loads waits in the stream and is processed right after.
                guard let engine = try await transcriber.streamingEngine(for: model, modelManager: modelManager) else { return nil }
                await engine.beginStream()
                var pending: [Float] = []
                for await chunk in stream {
                    pending += chunk
                    guard pending.count >= 1_600 else { continue }   // hand over ~0.1 s at a time
                    let partial = try await engine.feed(pending)
                    pending.removeAll(keepingCapacity: true)
                    if showLive, let self, self.status == .recording {
                        let text = PostProcessor.clean(partial, removeFillers: removeFillers)
                        if !text.isEmpty { self.liveTranscript = text }
                    }
                }
                if Task.isCancelled { return nil }
                if !pending.isEmpty { _ = try await engine.feed(pending) }
                return try await engine.finishStream()
            } catch {
                log.error("Streaming transcription failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
    }

    /// Stops sending audio to the streaming model. The returned task finishes the transcript.
    private func stopStreaming() -> Task<String?, Never>? {
        recorder.onSamples = nil
        streamInput?.finish()
        streamInput = nil
        let task = streamTask
        streamTask = nil
        return task
    }

    /// Stops the live preview; returns its task so the final transcription can wait for an in-flight
    /// preview to finish (the speech model runs one transcription at a time).
    private func stopLivePreview() -> Task<Void, Never>? {
        let task = livePreviewTask
        livePreviewTask = nil
        task?.cancel()
        return task
    }

    func cancelRecording() {
        guard status == .recording else { return }
        _ = stopLivePreview()
        stopStreaming()?.cancel()
        maxDurationTask?.cancel()
        _ = recorder.stop()
        silencer.restore()
        hotkeys.recordingActive = false
        flash(.done("Cancelled"))
    }

    func endRecording(_ action: HotkeyAction) {
        guard status == .recording, action == currentAction else { return }
        let preview = stopLivePreview()
        maxDurationTask?.cancel()
        hotkeys.recordingActive = false

        let samples = recorder.stop()
        silencer.restore()                // sound back the moment you let go
        let streaming = stopStreaming()   // after stop(), so the last audio has been handed over
        let duration = Double(samples.count) / AudioRecorder.sampleRate

        // Ignore taps and silence (Whisper tends to hallucinate on silence).
        guard duration >= 0.3, AudioRecorder.rms(samples) > 0.004 else {
            streaming?.cancel()
            status = .idle
            return
        }

        status = .transcribing
        Sounds.play(.stop, enabled: preferences.playSounds)

        let model = preferences.selectedModel
        let language = preferences.languageCode
        let removeFillers = preferences.removeFillers

        Task {
            await preview?.value
            do {
                let sttStarted = Date()
                // Streaming models already have the text; others (or a failed stream) transcribe now.
                var raw = await streaming?.value ?? ""
                if raw.trimmingCharacters(in: .whitespaces).isEmpty {
                    raw = try await transcriber.transcribe(samples, model: model, language: language, modelManager: modelManager)
                }
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
                NSLog("Duck Keyboard transcription error: \(error)")
            }
        }
    }

    // MARK: - Dictation

    private func paste(_ text: String, duration: Double, model: SpeechModel) async {
        let app = targetApp
        // Make sure the app you were typing in is in front again, and give it a moment to
        // restore focus to its text field before ⌘V arrives.
        if let app, app != NSWorkspace.shared.frontmostApplication {
            app.activate()
            try? await Task.sleep(for: .milliseconds(200))
        }
        // Wait until the hotkey's modifier is physically released so it can't combine with ⌘V.
        for _ in 0..<20 where !NSEvent.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
            try? await Task.sleep(for: .milliseconds(15))
        }
        let result = TextInserter.insert(text, restoreClipboard: preferences.restoreClipboard)
        saveHistory(DictationRecord(
            text: text, duration: duration, modelName: model.name,
            appName: app?.localizedName, appBundleID: app?.bundleIdentifier
        ))
        // Show what was typed in the popup; it closes by itself after a few seconds.
        status = .idle
        var shown = DictationResult(text: text, pasted: result.reachedApp, appName: app?.localizedName)
        switch result {
        case .copiedOnly(let reason):
            shown.copyReason = reason
            log.info("Not pasted (\(String(describing: reason), privacy: .public)); text left on the clipboard")
        case .pasted(let focusConfirmed):
            shown.unconfirmed = !focusConfirmed
        case .inserted:
            break
        }
        dictation = shown   // closes by itself shortly after (see watchIslandAutoClose)
    }

    // MARK: - Writing tools (fix grammar, write as email, professional, rude, custom)

    /// Hooks each writing tool's shortcut up once. The handler looks the action up when it fires, so
    /// prompt and title edits apply straight away; shortcuts of disabled or deleted actions are switched off.
    private func configureTextActions() {
        let actions = preferences.textActions
        for action in actions where !registeredTextActions.contains(action.id) {
            registeredTextActions.insert(action.id)
            let id = action.id
            // Fires when the key goes up, so it isn't mixed into the ⌘A / ⌘C that follow.
            KeyboardShortcuts.onKeyUp(for: action.shortcutName) {
                Task { @MainActor in AppState.shared.runTextAction(id: id) }
            }
        }
        let live = preferences.grammarFixEnabled ? Set(actions.filter(\.enabled).map(\.id)) : []
        for id in registeredTextActions {
            let name = TextActionCatalog.shortcutName(for: id)
            if live.contains(id) {
                KeyboardShortcuts.enable(name)
            } else {
                KeyboardShortcuts.disable(name)
            }
        }
    }

    /// A writing tool's shortcut: ⌘A + ⌘C in the focused field, rewrite the text with the local AI
    /// model and the action's prompt, then paste it back over the selection. The clipboard is put back.
    func runTextAction(id: String) {
        guard preferences.grammarFixEnabled,
              let action = preferences.textActions.first(where: { $0.id == id }), action.enabled else { return }
        guard !isBusy, !meetings.isRecording else {
            flash(.error("Busy · try again in a moment"))
            return
        }
        guard !action.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            flash(.error("“\(action.title)” has no prompt · add one in Settings › Grammar"))
            return
        }
        // The writing-tools model picked in Settings › Models if it's downloaded, else the assistant's.
        let chat = preferences.writingModel.flatMap { modelManager.isDownloaded($0) ? $0 : nil }
            ?? preferences.chatModel
        guard modelManager.isDownloaded(chat) else {
            flash(.error("Download \(chat.name) to use writing tools"))
            return
        }
        if isSpeaking { stopSpeaking() }
        dismissDictation()
        let app = NSWorkspace.shared.frontmostApplication
        rewriteLabel = action.progressLabel
        status = .transcribing   // popup: "Write as email…"
        grammarTask?.cancel()
        grammarTask = Task { [weak self] in
            await self?.runRewrite(action, in: app, model: chat)
            self?.rewriteLabel = nil
        }
    }

    private func runRewrite(_ action: TextAction, in app: NSRunningApplication?, model: ChatModel) async {
        let pasteboard = NSPasteboard.general
        let savedClipboard = TextInserter.snapshot(pasteboard)
        let putClipboardBack = preferences.restoreClipboard
        func restoreClipboard() {
            if putClipboardBack { TextInserter.restore(savedClipboard, to: pasteboard) }
        }

        // Start loading the model while the text is copied (usually it's already loaded).
        Task { [llm] in try? await llm.prepare(model) }
        await waitForModifierKeysUp()

        let original: String
        switch await GrammarFixer.copyAllFromFocusedField() {
        case .text(let text):
            original = text
        case .empty:
            flash(.error("No text found · click into a text field first"))
            return
        case .notText:
            restoreClipboard()
            flash(.error("That isn't text · click into a text field first"))
            return
        case .noPermission:
            flash(.error("Allow Accessibility for Duck Keyboard to use writing tools"))
            return
        case .secureInput:
            flash(.error("Can't read this field (secure input is on)"))
            return
        }
        guard original.count <= GrammarFixer.maxCharacters else {
            restoreClipboard()
            flash(.error("Too much text · up to 8,000 characters at a time"))
            return
        }

        let started = Date()
        let rewritten: String
        do {
            let raw = try await llm.generate(original, instructions: TextActionCatalog.instructions(for: action), model: model,
                                             maxTokens: GrammarFixer.maxTokens(for: original, rewriting: !action.keepsLength),
                                             temperature: action.keepsLength ? 0.1 : 0.4)
            rewritten = GrammarFixer.clean(raw, original: original)
        } catch {
            restoreClipboard()
            if !Task.isCancelled { flash(.error("AI error: \(error.localizedDescription)")) }
            log.error("\(action.title, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard !Task.isCancelled else {
            restoreClipboard()
            return
        }
        log.info("\(action.title, privacy: .public): \(Date().timeIntervalSince(started), format: .fixed(precision: 2))s for \(original.count) characters")

        let usable = action.keepsLength
            ? GrammarFixer.looksLikeCorrection(rewritten, of: original)
            : !rewritten.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard usable else {
            restoreClipboard()
            flash(.error("Couldn't rewrite that text · nothing was changed"))
            return
        }
        guard rewritten != original else {
            restoreClipboard()
            flash(.done(action.keepsLength ? "No mistakes found" : "Nothing to change"))
            return
        }

        // Back to the app you were typing in, with all of its text selected again (in case the
        // selection was lost while the AI was working), then paste over it.
        if let app, app != NSWorkspace.shared.frontmostApplication {
            app.activate()
            try? await Task.sleep(for: .milliseconds(200))
        }
        await waitForModifierKeysUp()
        GrammarFixer.selectAll()
        try? await Task.sleep(for: .milliseconds(80))
        let result = TextInserter.insert(rewritten, restoreClipboard: false)

        if case .copiedOnly = result {
            flash(.error("Result copied · press ⌘V to paste it"))
        } else {
            flash(.done(action.keepsLength ? "Grammar fixed" : "Done: \(action.title)"))
            lastRewriteAt = Date()
            if putClipboardBack {
                // Give slow apps time to read the clipboard before it's put back (as for dictation).
                let ours = pasteboard.changeCount
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    guard pasteboard.changeCount == ours else { return }
                    TextInserter.restore(savedClipboard, to: pasteboard)
                }
            }
        }
        saveHistory(DictationRecord(
            text: original, duration: 0, modelName: "\(action.title) · \(model.name)",
            appName: app?.localizedName, appBundleID: app?.bundleIdentifier, kind: "rewrite", answer: rewritten
        ))
    }

    /// Waits (up to about 1.5 seconds) until no modifier key is physically held (e.g. the ⌘ of ⌘E),
    /// so it can't combine with the ⌘A / ⌘C / ⌘V that are sent next.
    private func waitForModifierKeysUp() async {
        for _ in 0..<100 where !NSEvent.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
            try? await Task.sleep(for: .milliseconds(15))
        }
    }

    // MARK: - Popup auto-close

    /// How long a finished card stays up before the island tucks itself away.
    private static let islandCloseDelay: Double = 1.0
    /// Errors stay a little longer so there's time to read them.
    private static let islandErrorCloseDelay: Double = 3.0

    /// True when the card on screen has nothing left to do: the transcript was pasted, or the AI
    /// answer has finished writing and speaking (and isn't waiting for Run / Cancel).
    /// Pointing at the card keeps it open; moving away starts the countdown again.
    private var islandCanAutoClose: Bool {
        guard status == .idle, !isHoveringIsland else { return false }
        switch islandMode {
        case .dictation:
            return true
        case .answer:
            guard let reply else { return false }
            return !reply.isStreaming && !isSpeaking && reply.command?.needsConfirmation != true
        default:
            return false
        }
    }

    /// Watches `islandCanAutoClose` and closes the card about a second after it becomes true.
    private func watchIslandAutoClose() {
        let ready = withObservationTracking {
            islandCanAutoClose
        } onChange: { [weak self] in
            Task { @MainActor in self?.watchIslandAutoClose() }
        }
        guard ready else {
            islandCloseTask?.cancel()
            islandCloseTask = nil
            return
        }
        guard islandCloseTask == nil else { return }   // countdown already running
        let delay = reply?.error != nil ? Self.islandErrorCloseDelay : Self.islandCloseDelay
        islandCloseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.islandCloseTask = nil
            guard self.islandCanAutoClose, self.pendingCommand == nil else { return }
            self.dictation = nil
            if self.reply != nil {
                self.reply = nil
                self.assistantTask = nil
            }
        }
    }

    func dismissDictation() {
        dictation = nil
    }

    func copyDictation() {
        guard let text = dictation?.text else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Pointing at a card keeps it open; moving away lets it close again (see watchIslandAutoClose).
    func setIslandHovering(_ hovering: Bool) {
        guard hovering != isHoveringIsland else { return }
        isHoveringIsland = hovering
    }

    // MARK: - AI assistant

    /// Starts loading the chat model (and the voice) as soon as the AI hotkey goes down.
    /// Both are usually already loaded (see `warmUpModels`); this covers the case where they were unloaded.
    private func preloadAssistant() {
        let chat = preferences.chatModel
        if modelManager.isDownloaded(chat) {
            Task { [llm] in try? await llm.prepare(chat) }
        }
        if preferences.replyStyle.speaks, let folder = modelManager.localFolder(for: preferences.voiceModel) {
            let variant = preferences.voiceModel.id
            let voice = preferences.voice
            let language = preferences.languageCode
            Task { [speech] in try? await speech.prepare(variant: variant, folder: folder, voice: voice, languageCode: language) }
        }
    }

    /// Mac commands ("open Xcode") run straight away; everything else goes to the AI.
    private func ask(_ question: String, duration: Double) {
        // A risky command is waiting: "yes" / "no" answers it by voice.
        if pendingCommand != nil {
            let answer = CommandParser.clean(question)
            if ["yes", "yeah", "yep", "sure", "do it", "go ahead", "confirm", "run it", "ok", "okay", "run"].contains(answer) {
                confirmPendingCommand()
                return
            }
            if ["no", "nope", "cancel", "don't", "do not", "stop", "never mind", "nevermind", "don't do it"].contains(answer) {
                cancelPendingCommand()
                return
            }
            pendingCommand = nil
        }
        if preferences.macCommandsEnabled, let command = CommandParser.parse(question) {
            log.info("Recognised command: \(command.title, privacy: .public)")
            perform(command, question: question, duration: duration, fallBackToAI: true)
            return
        }
        // Not a phrasing the parser knows: try matching it to a command by meaning
        // ("xcode kholo", "awaaz kam karo", "make it louder").
        if preferences.macCommandsEnabled, preferences.memoryEnabled, preferences.commandMatching != .off,
           memory.commands.isReady {
            status = .transcribing
            Task { [weak self] in
                guard let self else { return }
                let result = await self.memory.commands.match(question)
                self.handleCommandMatch(result, question: question, duration: duration)
            }
            return
        }
        askAI(question, duration: duration)
    }

    private func handleCommandMatch(_ result: CommandIntentMatcher.Result, question: String, duration: Double) {
        switch result {
        case .run(let phrase, let score):
            guard let command = CommandParser.parse(phrase) else {
                askAI(question, duration: duration)
                return
            }
            log.info("Matched by meaning: “\(question, privacy: .public)” → \(phrase, privacy: .public) (\(score, format: .fixed(precision: 2)))")
            if preferences.commandMatching == .suggest {
                showSuggestions([phrase], for: question)
            } else {
                // Risky commands found by meaning always ask first, whatever the setting.
                perform(command, question: question, duration: duration, fallBackToAI: true, forceConfirm: command.isRisky)
            }
        case .suggest(let phrases):
            // Could be a question that sounds like a command ("how do I take a screenshot?"):
            // answer it, and offer the commands under the answer.
            askAI(question, duration: duration, suggestions: phrases)
        case .none:
            askAI(question, duration: duration)
        }
    }

    /// “Did you mean…” card with Try buttons, nothing else.
    private func showSuggestions(_ phrases: [String], for question: String) {
        reply = AssistantReply(question: question, answer: "Did you mean one of these? Click to run it.",
                               isStreaming: false, suggestions: phrases)
        status = .idle
    }

    private func askAI(_ question: String, duration: Double, suggestions: [String] = []) {
        let style = preferences.replyStyle
        let chat = preferences.chatModel
        guard modelManager.isDownloaded(chat) else {
            flash(.error("Download \(chat.name) to ask questions"))
            return
        }
        let allowActions = preferences.macCommandsEnabled && preferences.aiCommandsEnabled
        reply = AssistantReply(question: question, suggestions: suggestions)
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
                let stream = try await llm.ask(question, model: chat, allowActions: allowActions)
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
                    // The model may answer with "ACTION: …" (a Mac command): hold the text back until it's clear.
                    if allowActions, Self.actionState(shown) != .answer { continue }
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
                if allowActions, Self.actionState(answer) == .action {
                    if speaking { stopSpeaking() }
                    if Task.isCancelled { return }
                    let phrase = Self.actionPhrase(answer)
                    log.info("AI turned the question into a command: \(phrase, privacy: .public)")
                    if let command = CommandParser.parse(phrase) {
                        perform(command, question: question, duration: duration, fallBackToAI: false)
                    } else {
                        reply?.isStreaming = false
                        reply?.error = "I can't do that on this Mac yet. Open Duck Keyboard › Learn to see what I can do."
                        if !style.shows { flash(.error("Can't do that yet")) }
                    }
                    return
                }
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
                NSLog("Duck Keyboard AI error: \(error)")
            }
        }
    }

    /// Opens the voice for a new answer. Returns false if no voice model is downloaded.
    private func beginSpeaking() -> Bool {
        let voiceModel = preferences.voiceModel
        guard let folder = modelManager.localFolder(for: voiceModel) else {
            if reply != nil, reply?.error == nil {
                reply?.error = "Download a voice in Settings › Models to hear answers aloud."
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
        pendingCommand = nil
        stopSpeaking()
        reply = nil
    }

    // MARK: - Mac commands

    private enum ActionState { case undecided, action, answer }

    /// Whether the model's reply so far is a command ("ACTION: open Xcode"), might still become one, or is an answer.
    private static func actionState(_ text: String) -> ActionState {
        let head = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if head.hasPrefix("ACTION:") { return .action }
        if "ACTION:".hasPrefix(head) { return .undecided }
        return .answer
    }

    /// "ACTION: open Xcode." → "open Xcode"
    private static func actionPhrase(_ text: String) -> String {
        var phrase = text.trimmingCharacters(in: .whitespacesAndNewlines)
        phrase = String(phrase.dropFirst("ACTION:".count))
        phrase = phrase.split(separator: "\n").first.map(String.init) ?? ""
        return phrase.trimmingCharacters(in: CharacterSet(charactersIn: " \"'“”‘’.`<>"))
    }

    /// Runs a command now, or asks first when it's risky and "Ask before risky actions" is on.
    private func perform(_ command: MacCommand, question: String, duration: Double, fallBackToAI: Bool,
                         forceConfirm: Bool = false) {
        if command.isRisky && (preferences.confirmRiskyCommands || forceConfirm) {
            pendingCommand = (command, question, duration)
            reply = AssistantReply(
                question: question,
                answer: "Run “\(command.title)”? Click Run, or hold the AI key and say yes.",
                isStreaming: false,
                command: CommandBadge(title: command.title, symbol: command.symbol, needsConfirmation: true)
            )
            status = .idle
            return
        }
        runCommand(command, question: question, duration: duration, fallBackToAI: fallBackToAI)
    }

    func confirmPendingCommand() {
        guard let pending = pendingCommand else { return }
        pendingCommand = nil
        reply = nil
        runCommand(pending.command, question: pending.question, duration: pending.duration, fallBackToAI: false)
    }

    func cancelPendingCommand() {
        pendingCommand = nil
        reply = nil
        flash(.done("Cancelled"))
    }

    /// Runs a command from inside the app (the Try buttons in Learn), as if it had been spoken.
    func tryCommand(_ phrase: String) {
        guard !isBusy, !meetings.isRecording, let command = CommandParser.parse(phrase) else { return }
        currentAction = .assistant
        targetApp = NSWorkspace.shared.frontmostApplication
        perform(command, question: phrase, duration: 0, fallBackToAI: false)
    }

    private func runCommand(_ command: MacCommand, question: String, duration: Double, fallBackToAI: Bool) {
        // Screenshots shouldn't catch the popup; everything else shows "Thinking…" while it runs.
        if case .screenshot = command { status = .idle } else { status = .transcribing }
        let context = CommandContext(targetApp: targetApp, restoreClipboard: preferences.restoreClipboard)
        let appName = targetApp?.localizedName
        let appBundleID = targetApp?.bundleIdentifier
        commandTask?.cancel()
        commandTask = Task {
            let outcome = await commands.run(command, context: context)
            guard !Task.isCancelled else { return }
            let badge = CommandBadge(title: command.title, symbol: command.symbol)
            let result: String
            switch outcome {
            case .notHandled:
                // Not a command after all ("start a business plan"): let the AI answer it.
                if fallBackToAI {
                    askAI(question, duration: duration)
                } else {
                    reply = nil
                    flash(.error("I didn't catch that"))
                }
                return
            case .done(let message):
                reply = nil
                flash(.done(message))
                result = message
                lastCommand = (command.title, Date())
            case .answer(let text):
                showCommandResult(text, question: question, badge: badge, isError: false)
                result = text
                lastCommand = (command.title, Date())
            case .failed(let message):
                showCommandResult(message, question: question, badge: badge, isError: true)
                result = message
            }
            log.info("Command finished: \(result, privacy: .public)")
            saveHistory(DictationRecord(
                text: question, duration: duration, modelName: "Mac command",
                appName: appName, appBundleID: appBundleID, kind: "assistant", answer: result
            ))
        }
    }

    /// Information and problems go on the answer card, and are read aloud if Settings › Answers says so.
    private func showCommandResult(_ text: String, question: String, badge: CommandBadge, isError: Bool) {
        let style = preferences.replyStyle
        reply = AssistantReply(question: question, answer: isError ? "" : text, isStreaming: false,
                               error: isError ? text : nil, command: badge)
        if style.shows {
            status = .idle
        } else {
            flash(isError ? .error("Couldn't do that") : .done(badge.title))
        }
        if style.speaks { speak(text) }
    }

    /// A voice timer or reminder went off. The macOS notification shows too.
    private func timerFired(_ timer: ActiveTimer) {
        NSSound(named: NSSound.Name("Glass"))?.play()
        guard !isBusy else { return }
        let style = preferences.replyStyle
        let title = timer.isReminder ? "Reminder" : "Timer done"
        reply = AssistantReply(question: "", answer: timer.doneMessage, isStreaming: false,
                               command: CommandBadge(title: title, symbol: timer.isReminder ? "bell.fill" : "timer"))
        if !style.shows { flash(.done(title)) }
        if style.speaks { speak(timer.doneMessage) }
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

    /// One time: copies meetings saved in the shared default file (before they had their own store)
    /// into the meetings store, so nothing recorded so far is lost by the switch.
    private static func moveMeetingsToOwnStore() {
        let key = "meetingsMovedToOwnStore"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        defer { UserDefaults.standard.set(true, forKey: key) }
        do {
            let old = try ModelContainer(for: DictationRecord.self, Meeting.self)
            let meetings = try ModelContext(old).fetch(FetchDescriptor<Meeting>())
            guard !meetings.isEmpty else { return }
            let config = ModelConfiguration("Meetings", schema: Schema([Meeting.self]), url: MeetingStorage.storeURL)
            let target = ModelContext(try ModelContainer(for: Meeting.self, configurations: config))
            for meeting in meetings { target.insert(meeting.detachedCopy()) }
            try target.save()
            NSLog("Duck Keyboard: moved %d meetings to their own store", meetings.count)
        } catch {
            NSLog("Duck Keyboard: moving meetings to their own store failed: \(error)")
        }
    }

    /// Writes any unsaved changes (called when the app quits).
    func saveData() {
        do {
            try container.mainContext.save()
        } catch {
            log.error("Saving data failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Model warm-up (used by onboarding)

    func warmUpSelectedModel() async throws {
        try await transcriber.prepare(model: preferences.selectedModel, modelManager: modelManager)
    }
}
