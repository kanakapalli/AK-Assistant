import SwiftUI
import ServiceManagement

/// First-launch flow: welcome -> microphone -> accessibility -> speech model -> AI assistant -> hotkeys -> try it.
struct OnboardingView: View {
    enum Step: Int, CaseIterable {
        case welcome, microphone, accessibility, model, assistant, hotkey, tryIt

        var title: String {
            switch self {
            case .welcome: return "Welcome"
            case .microphone: return "Microphone"
            case .accessibility: return "Accessibility"
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
    @State private var micGranted = Permissions.microphoneGranted
    @State private var axGranted = Permissions.accessibilityGranted
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
                Button(step == .tryIt ? "Finish" : "Continue") {
                    if step == .tryIt { finish() } else { move(1) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canContinue)
            }
            .padding(20)
        }
        .onChange(of: modelManager.states) {
            // Downloaded a model other than the highlighted one? Select it, so Continue unlocks.
            guard step == .model, !modelManager.isDownloaded(preferences.selectedModel),
                  let ready = ModelCatalog.all.first(where: { modelManager.isDownloaded($0) })
            else { return }
            preferences.selectedModelID = ready.id
        }
        .task {
            // Poll permission status so the steps unlock as soon as the user grants access.
            while !Task.isCancelled {
                micGranted = Permissions.microphoneGranted
                axGranted = Permissions.accessibilityGranted
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

        case .microphone:
            StepHeader(symbol: "mic", title: "Allow the microphone",
                       text: "Duck Keyboard only listens while you hold the hotkey. Audio stays in memory and is discarded after transcription.")
            PermissionStatus(granted: micGranted, button: "Allow Microphone") {
                Task {
                    micGranted = await Permissions.requestMicrophone()
                    if !micGranted { Permissions.openMicrophoneSettings() }
                }
            }

        case .accessibility:
            StepHeader(symbol: "hand.raised", title: "Allow Accessibility",
                       text: "This lets Duck Keyboard notice your push-to-talk key in any app and paste the text into the focused field. Turn on Duck Keyboard in System Settings > Privacy & Security > Accessibility, then come back.")
            PermissionStatus(granted: axGranted, button: "Open System Settings") {
                Permissions.requestAccessibility()
                Permissions.openAccessibilitySettings()
            }

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
        case .microphone: return micGranted
        case .accessibility: return axGranted
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

private struct PermissionStatus: View {
    let granted: Bool
    let button: String
    let action: () -> Void

    var body: some View {
        HStack {
            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.headline)
            } else {
                Button(button, action: action)
                    .controlSize(.large)
            }
            Spacer()
        }
    }
}
