import SwiftUI
import ServiceManagement

/// First-launch flow: welcome -> permissions (all of them, in one place) -> speech model -> AI assistant -> hotkeys -> try it.
struct OnboardingView: View {
    enum Step: Int, CaseIterable {
        case welcome, permissions, model, assistant, hotkey, tryIt

        var title: String {
            switch self {
            case .welcome: return "Welcome"
            case .permissions: return "Permissions"
            case .model: return "Model"
            case .assistant: return "AI"
            case .hotkey: return "Hotkey"
            case .tryIt: return "Try it"
            }
        }
    }

    @Environment(AppState.self) private var appState
    @Environment(Preferences.self) private var preferences
    @Environment(ModelManager.self) private var modelManager

    @State private var step: Step = .welcome
    /// Where onboarding was when the app quit, so "Restart Duck Keyboard" (needed for some
    /// permissions to take effect) comes back to the same step.
    @AppStorage("onboardingStep") private var savedStep = 0
    @State private var permissions = PermissionSnapshot()
    @State private var warmingUp = false
    @State private var warmUpStarted: Date?
    @State private var warmUpError: String?
    @State private var tryText = ""
    /// On by default: a dictation app is most useful when it's already running after a restart.
    @State private var launchAtLogin = true

    var body: some View {
        VStack(spacing: 0) {
            StepIndicator(current: step)
                .padding(.top, 24)
            Divider().padding(.top, 16)

            ScrollView {
                content
                    .frame(maxWidth: 640)
                    .padding(32)
                    .frame(maxWidth: .infinity)
            }

            Divider()
            HStack {
                if step != .welcome {
                    Button("Back") { move(-1) }
                }
                Spacer()
                if step == .permissions && permissions.requiredReady && !permissions.allReady {
                    Text("You can turn the rest on later in Settings › Permissions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button(step == .tryIt ? "Finish" : "Continue") {
                    if step == .tryIt { finish() } else { move(1) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canContinue)
            }
            .padding(20)
        }
        .onAppear {
            if let saved = Step(rawValue: savedStep), saved != .welcome {
                step = saved
            }
        }
        .onChange(of: step) { savedStep = step.rawValue }
        .onChange(of: modelManager.states) {
            // Downloaded a model other than the highlighted one? Select it, so Continue unlocks.
            guard step == .model, !modelManager.isDownloaded(preferences.selectedModel),
                  let ready = ModelCatalog.all.first(where: { modelManager.isDownloaded($0) })
            else { return }
            preferences.selectedModelID = ready.id
        }
        .onChange(of: permissions.hotkeyRelevant) {
            // Accessibility, Input Monitoring or Send keystrokes just turned on: re-arm the key
            // monitors now, so the Try it step works without restarting.
            appState.permissionsChanged()
        }
        .task {
            // Poll permission status so the steps unlock as soon as the user grants access.
            while !Task.isCancelled {
                permissions = await .current()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    // MARK: - Steps

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome:
            StepHeader(symbol: "waveform", title: "Dictate anywhere on your Mac",
                       text: "Hold a key, speak, let go. Duck Keyboard turns your voice into text and pastes it wherever your cursor is. Hold a second key to ask a local AI anything and hear the answer. Everything runs on this Mac with open-source models; your audio and questions never leave it.")

        case .permissions:
            PermissionsStep(permissions: $permissions)

        case .model:
            StepHeader(symbol: "cpu", title: "Choose a speech model",
                       text: "Pick one to download now. You can add or switch models later in the Models tab.")
            VStack(spacing: 10) {
                ForEach(ModelCatalog.all) { model in
                    ModelCard(model: model, selected: preferences.selectedModelID == model.id) {
                        preferences.selectedModelID = model.id
                    }
                }
            }
            .padding(.top, 8)
            if warmingUp, let warmUpStarted {
                WarmUpStatus(started: warmUpStarted) {
                    // Let the user carry on; the load keeps running and the first dictation waits for it.
                    warmingUp = false
                    step = .assistant
                }
                .padding(.top, 8)
            }
            if let warmUpError {
                Text(warmUpError).foregroundStyle(.red).font(.callout)
            }
            if !modelManager.isDownloaded(preferences.selectedModel) && !warmingUp {
                Text("Download the selected model to continue.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }

        case .assistant:
            AssistantSetupStep()

        case .hotkey:
            StepHeader(symbol: "keyboard", title: "Pick your keys",
                       text: "Hold a key to record and release it to act. Press Esc while holding to cancel.")
            Form {
                Section("Dictation: paste what you say") {
                    HotkeyPicker(action: .dictate)
                }
                if preferences.assistantEnabled {
                    Section("AI assistant: ask a question") {
                        HotkeyPicker(action: .assistant)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(maxHeight: 300)

        case .tryIt:
            StepHeader(symbol: "text.cursor", title: "Try it",
                       text: preferences.assistantEnabled
                        ? "Click in the box, hold \(preferences.hotkey.title), say something, and let go. Then hold \(preferences.assistantHotkey.title) and ask the AI a question."
                        : "Click in the box, hold \(preferences.hotkey.title), say something, and let go.")
            if !permissions.requiredReady {
                // Something was switched off since the Permissions step; dictation would only copy.
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Duck Keyboard can't paste yet: \(permissions.missingRequired.joined(separator: ", ")) is off.")
                    Spacer()
                    Button("Fix") { step = .permissions }
                }
                .font(.callout)
                .padding(10)
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }
            TextEditor(text: $tryText)
                .font(.body)
                .frame(height: 140)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.secondary.opacity(0.3)))
            Toggle("Open Duck Keyboard automatically when I log in", isOn: $launchAtLogin)
                .toggleStyle(.switch)
                .padding(.top, 12)
            Text("You can change this later in Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("After this, Duck Keyboard keeps running in the menu bar. Open this window from the menu bar icon to see your history.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
        }
    }

    private var canContinue: Bool {
        switch step {
        case .permissions: return permissions.requiredReady
        case .model: return modelManager.isDownloaded(preferences.selectedModel) && !warmingUp
        default: return true
        }
    }

    private func finish() {
        let service = SMAppService.mainApp
        do {
            if launchAtLogin, service.status != .enabled {
                try service.register()
            } else if !launchAtLogin, service.status == .enabled {
                try service.unregister()
            }
        } catch {
            // Not fatal: the user can turn it on later in Settings (macOS may ask for approval there).
            NSLog("Duck Keyboard launch-at-login error: \(error)")
        }
        savedStep = 0
        appState.permissionsChanged()
        preferences.onboarded = true
    }

    private func move(_ delta: Int) {
        guard let next = Step(rawValue: step.rawValue + delta) else { return }
        if step == .model && delta > 0 {
            // Load once so the first real dictation is fast.
            warmingUp = true
            warmUpStarted = .now
            warmUpError = nil
            Task {
                do {
                    try await appState.warmUpSelectedModel()
                    guard warmingUp else { return }   // user already skipped ahead
                    warmingUp = false
                    step = next
                } catch {
                    warmingUp = false
                    warmUpError = "Couldn't load the model: \(error.localizedDescription)"
                }
            }
            return
        }
        step = next
    }
}

// MARK: - Permissions

/// Every permission Duck Keyboard uses, read in one go.
struct PermissionSnapshot: Equatable {
    var microphone = Permissions.microphoneGranted
    var accessibility = Permissions.accessibilityGranted
    var sendKeystrokes = Permissions.canSendKeystrokes
    var inputMonitoring = Permissions.inputMonitoringGranted
    var screenCapture = Permissions.screenCaptureGranted
    var notifications: Permissions.Grant = .notAsked
    var automation: Permissions.Grant = .notAsked

    /// Dictation can't paste without these three.
    var requiredReady: Bool { microphone && accessibility && sendKeystrokes }

    var allReady: Bool {
        requiredReady && inputMonitoring && screenCapture && notifications == .granted && automation == .granted
    }

    var missingRequired: [String] {
        var names: [String] = []
        if !microphone { names.append("Microphone") }
        if !accessibility { names.append("Accessibility") }
        if !sendKeystrokes { names.append("Paste into other apps") }
        return names
    }

    /// The ones that decide whether the key monitors and paste work.
    var hotkeyRelevant: [Bool] { [accessibility, inputMonitoring, sendKeystrokes] }

    /// Reads everything again; macOS has no change notifications for most of these.
    static func current() async -> PermissionSnapshot {
        var snapshot = PermissionSnapshot()
        snapshot.notifications = await Permissions.notificationStatus()
        snapshot.automation = await Permissions.automationStatus(ask: false)
        return snapshot
    }
}

/// Onboarding step that asks for every permission on one page, so nothing is missing later.
private struct PermissionsStep: View {
    @Binding var permissions: PermissionSnapshot
    /// Set once the user has been sent to System Settings; then a restart may be needed.
    @State private var visitedSettings = false
    @State private var askingAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StepHeader(symbol: "lock.shield", title: "Allow permissions",
                       text: "Duck Keyboard needs a few macOS permissions to hear you, see your hotkeys and paste the text. Grant them all here so every feature works from the start. Nothing leaves your Mac.")

            HStack {
                Button {
                    Task { await allowAll() }
                } label: {
                    Label(askingAll ? "Asking…" : "Allow all", systemImage: "checkmark.shield")
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(askingAll || permissions.allReady)
                Text(permissions.allReady ? "Everything is allowed." : "macOS shows a prompt or opens System Settings for each one. Switch on Duck Keyboard there, then come back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 4)

            Text("Required for dictation").font(.headline).padding(.top, 4)
            PermissionCard(symbol: "mic", title: "Microphone",
                           detail: "Hear you while you hold a key or record a meeting you start.",
                           state: permissions.microphone ? .granted : .missing, button: "Allow") {
                Task {
                    if !(await Permissions.requestMicrophone()) { Permissions.openMicrophoneSettings() }
                    permissions = await .current()
                }
            }
            PermissionCard(symbol: "hand.raised", title: "Accessibility",
                           detail: "See your hotkeys in any app and type into the focused text field.",
                           state: permissions.accessibility ? .granted : .missing, button: "Open Settings") {
                Permissions.requestAccessibility()
                Permissions.openAccessibilitySettings()
                visitedSettings = true
            }
            PermissionCard(symbol: "doc.on.clipboard", title: "Paste into other apps",
                           detail: "Lets Duck Keyboard press ⌘V for you. It's listed under Accessibility too; it may only show as on after a restart.",
                           state: permissions.sendKeystrokes ? .granted : .missing, button: "Allow") {
                Permissions.requestSendKeystrokes()
                Permissions.openAccessibilitySettings()
                visitedSettings = true
            }

            Text("For hotkeys, the AI and meetings").font(.headline).padding(.top, 8)
            PermissionCard(symbol: "keyboard", title: "Input Monitoring",
                           detail: "Some Macs need this as well to notice your hotkeys while other apps are in front.",
                           state: permissions.inputMonitoring ? .granted : .missing, button: "Allow") {
                Permissions.requestInputMonitoring()
                Permissions.openInputMonitoringSettings()
                visitedSettings = true
            }
            PermissionCard(symbol: "gearshape.2", title: "Automation",
                           detail: "Run Mac commands you ask for, like dark mode, Empty Trash or restart (System Events and Finder).",
                           state: permissions.automation.cardState, button: "Allow") {
                Task {
                    if permissions.automation == .denied {
                        Permissions.openAutomationSettings()
                        visitedSettings = true
                    } else {
                        _ = await Permissions.automationStatus(ask: true)
                    }
                    permissions = await .current()
                }
            }
            PermissionCard(symbol: "bell.badge", title: "Notifications",
                           detail: "Tell you when a timer or reminder you set goes off.",
                           state: permissions.notifications.cardState, button: "Allow") {
                Task {
                    _ = await Permissions.requestNotifications()
                    permissions = await .current()
                }
            }
            PermissionCard(symbol: "rectangle.dashed.badge.record", title: "Screen & System Audio Recording",
                           detail: "Record the other people on a Zoom, Meet or Teams call. Only the sound is used, never the picture.",
                           state: permissions.screenCapture ? .granted : .missing, button: "Allow") {
                Permissions.requestScreenCapture()
                Permissions.openScreenCaptureSettings()
                visitedSettings = true
            }

            if visitedSettings && !permissions.allReady {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Switched them on but they still show as missing?")
                        .font(.callout.weight(.semibold))
                    Text("macOS applies Paste, Input Monitoring and Screen Recording to Duck Keyboard only after it restarts. Setup continues right here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Restart Duck Keyboard") { Permissions.relaunch() }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                .padding(.top, 4)
            }
        }
    }

    /// Prompts that appear inside the app come first (they wait for an answer); the ones that
    /// live in System Settings are all registered at once, so the user only has to flip switches.
    private func allowAll() async {
        askingAll = true
        defer { askingAll = false }

        if !permissions.microphone, !(await Permissions.requestMicrophone()) {
            Permissions.openMicrophoneSettings()
        }
        if permissions.notifications != .granted { _ = await Permissions.requestNotifications() }
        if permissions.automation == .notAsked { _ = await Permissions.automationStatus(ask: true) }

        // These add Duck Keyboard to each System Settings list (switched off), ready to turn on.
        if !permissions.screenCapture { Permissions.requestScreenCapture() }
        if !permissions.inputMonitoring { Permissions.requestInputMonitoring() }
        if !permissions.sendKeystrokes { Permissions.requestSendKeystrokes() }
        if !permissions.accessibility {
            Permissions.requestAccessibility()
            Permissions.openAccessibilitySettings()
        } else if !permissions.sendKeystrokes {
            Permissions.openAccessibilitySettings()
        } else if !permissions.inputMonitoring {
            Permissions.openInputMonitoringSettings()
        } else if !permissions.screenCapture {
            Permissions.openScreenCaptureSettings()
        }
        visitedSettings = true
        permissions = await .current()
    }
}

private extension Permissions.Grant {
    var cardState: PermissionCard.Status {
        switch self {
        case .granted: return .granted
        case .denied: return .missing
        case .notAsked: return .notAsked
        }
    }
}

private struct PermissionCard: View {
    enum Status { case granted, missing, notAsked }

    let symbol: String
    let title: String
    let detail: String
    let state: Status
    let button: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if state == .granted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout.weight(.medium))
            } else {
                Button(button, action: action)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Shows how long the first-time model preparation has been running, and lets the user skip ahead.
private struct WarmUpStatus: View {
    let started: Date
    let onSkip: () -> Void

    var body: some View {
        // TimelineView redraws once a second so the elapsed time ticks.
        TimelineView(.periodic(from: started, by: 1)) { context in
            let seconds = Int(context.date.timeIntervalSince(started))
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading the model… \(seconds / 60):\(String(format: "%02d", seconds % 60))")
                        .monospacedDigit()
                }
                Text("The first load prepares the model for your Mac. It's usually under a minute on the GPU; later launches are faster.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if seconds >= 15 {
                    Button("Continue — finish in the background", action: onSkip)
                }
            }
        }
    }
}

/// Onboarding step for the AI assistant: turn it on, pick a chat model, choose how answers come back, pick a voice.
private struct AssistantSetupStep: View {
    @Environment(Preferences.self) private var preferences
    @Environment(ModelManager.self) private var modelManager

    var body: some View {
        @Bindable var preferences = preferences
        let enabled = Binding(
            get: { preferences.assistantEnabled },
            set: { on in
                // Default AI key: Right Command, or Right Option if dictation already uses Right Command.
                preferences.assistantHotkey = on ? (preferences.hotkey == .rightCommand ? .rightOption : .rightCommand) : .off
            }
        )

        VStack(alignment: .leading, spacing: 8) {
            StepHeader(symbol: "sparkles", title: "Set up the AI assistant",
                       text: "Hold a second key, ask anything, and a local AI answers. Downloads continue in the background, so you can keep going.")

            Toggle("Use the AI assistant", isOn: enabled)
                .toggleStyle(.switch)
                .padding(.bottom, 8)

            if preferences.assistantEnabled {
                Text("AI model").font(.headline).padding(.top, 4)
                VStack(spacing: 10) {
                    ForEach(AssistantCatalog.chatModels) { model in
                        ChatModelCard(model: model, selected: preferences.chatModelID == model.id) {
                            preferences.chatModelID = model.id
                        }
                    }
                }

                Text("How answers come back").font(.headline).padding(.top, 16)
                Picker("Answers", selection: $preferences.replyStyle) {
                    ForEach(ReplyStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(preferences.replyStyle.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if preferences.replyStyle.speaks {
                    Text("Voice").font(.headline).padding(.top, 16)
                    VStack(spacing: 10) {
                        ForEach(AssistantCatalog.voiceModels) { voice in
                            VoiceModelCard(voice: voice, selected: preferences.voiceModelID == voice.id) {
                                preferences.voiceModelID = voice.id
                            }
                        }
                    }
                    Picker("Speaker", selection: $preferences.voice) {
                        ForEach(AssistantCatalog.voices, id: \.id) { voice in
                            Text(voice.name).tag(voice.id)
                        }
                    }
                    .frame(maxWidth: 260)
                    .padding(.top, 4)
                }
            }
        }
    }
}

private struct StepIndicator: View {
    let current: OnboardingView.Step

    var body: some View {
        HStack(spacing: 8) {
            ForEach(OnboardingView.Step.allCases, id: \.self) { step in
                VStack(spacing: 4) {
                    Capsule()
                        .fill(step.rawValue <= current.rawValue ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(width: 64, height: 4)
                    Text(step.title)
                        .font(.caption2)
                        .foregroundStyle(step == current ? .primary : .secondary)
                }
            }
        }
    }
}

private struct StepHeader: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 34))
                .foregroundStyle(Color.accentColor)
            Text(title).font(.largeTitle.weight(.semibold))
            Text(text).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 12)
    }
}
