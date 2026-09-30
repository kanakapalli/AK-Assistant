import SwiftUI
import ServiceManagement
import KeyboardShortcuts

struct SettingsView: View {
    @Environment(Preferences.self) private var preferences
    @Environment(\.modelContext) private var context
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var micGranted = Permissions.microphoneGranted
    @State private var axGranted = Permissions.accessibilityGranted

    var body: some View {
        // @Bindable turns the @Observable object into bindings ($preferences.language, …) for controls.
        @Bindable var preferences = preferences

        Form {
            Section("Push-to-talk") {
                HotkeyPicker(action: .dictate)
                Text("Hold the key to record. Release it to transcribe and paste. Press Esc while holding to cancel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("AI assistant") {
                HotkeyPicker(action: .assistant)
                Text("Hold the key and ask a question. Release it and a local AI answers. Follow-up questions within 5 minutes continue the same conversation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if preferences.assistantEnabled {
                    ReplySettings()
                }
            }

            Section("Transcription") {
                Picker("Language", selection: $preferences.language) {
                    ForEach(Preferences.languages, id: \.code) { lang in
                        Text(lang.name).tag(lang.code)
                    }
                }
                Toggle("Remove filler words (um, uh)", isOn: $preferences.removeFillers)
                Toggle("Restore my clipboard after pasting", isOn: $preferences.restoreClipboard)
                Toggle("Use the Neural Engine (lower power, slow first load)", isOn: $preferences.useNeuralEngine)
                Text("Off: Whisper runs on the GPU and loads in seconds. On: uses less power, but the first load of each model can take several minutes while macOS optimizes it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                Toggle("Play start and stop sounds", isOn: $preferences.playSounds)
            }

            Section("History") {
                Picker("Keep history", selection: $preferences.historyRetentionDays) {
                    Text("Forever").tag(0)
                    Text("30 days").tag(30)
                    Text("7 days").tag(7)
                    Text("Don't save").tag(-1)
                }
                .onChange(of: preferences.historyRetentionDays) { _, days in
                    HistoryPruner.prune(context: context, retentionDays: days)
                }
            }

            Section("Permissions") {
                PermissionRow(title: "Microphone", granted: micGranted) {
                    Task {
                        micGranted = await Permissions.requestMicrophone()
                        if !micGranted { Permissions.openMicrophoneSettings() }
                    }
                }
                PermissionRow(title: "Accessibility (hotkey + paste)", granted: axGranted) {
                    Permissions.requestAccessibility()
                    Permissions.openAccessibilitySettings()
                }
            }

            Section {
                Button("Run onboarding again") { preferences.onboarded = false }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .task {
            // Re-check permissions while this screen is visible (the user may grant them in System Settings).
            while !Task.isCancelled {
                micGranted = Permissions.microphoneGranted
                axGranted = Permissions.accessibilityGranted
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

/// Picks the key for dictation or for the AI assistant. The two can't be the same key.
struct HotkeyPicker: View {
    @Environment(Preferences.self) private var preferences
    var action: HotkeyAction = .dictate

    var body: some View {
        @Bindable var preferences = preferences
        let selection = action == .dictate ? $preferences.hotkey : $preferences.assistantHotkey
        let other = action == .dictate ? preferences.assistantHotkey : preferences.hotkey

        Picker(action == .dictate ? "Hold to dictate" : "Hold to ask AI", selection: selection) {
            ForEach(HotkeyChoice.allCases.filter { action == .assistant || $0 != .off }) { choice in
                Text(choice.title).tag(choice)
            }
        }
        .onChange(of: selection.wrappedValue) { old, new in
            // Picked the key the other action uses: swap them so both keep working.
            guard new == other, new != .custom, new != .off else { return }
            if action == .dictate {
                preferences.assistantHotkey = old
            } else {
                // Dictation always needs a key: give it the old AI key, or the first free one.
                let free: [HotkeyChoice] = [.rightOption, .rightCommand, .rightControl, .fn]
                preferences.hotkey = old != .off ? old : (free.first { $0 != new } ?? .rightOption)
            }
        }
        if selection.wrappedValue == .custom {
            KeyboardShortcuts.Recorder("Shortcut", name: action.shortcutName)
        }
        if selection.wrappedValue == .fn {
            Text("Tip: set System Settings > Keyboard > \"Press 🌐 key to\" to \"Do Nothing\" so Fn doesn't open the emoji picker.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// How AI answers come back, and which voice reads them.
struct ReplySettings: View {
    @Environment(Preferences.self) private var preferences
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var preferences = preferences

        Picker("Answers", selection: $preferences.replyStyle) {
            ForEach(ReplyStyle.allCases) { style in
                Text(style.title).tag(style)
            }
        }
        Text(preferences.replyStyle.detail)
            .font(.caption)
            .foregroundStyle(.secondary)

        if preferences.replyStyle.speaks {
            HStack {
                Picker("Voice", selection: $preferences.voice) {
                    ForEach(AssistantCatalog.voices, id: \.id) { voice in
                        Text(voice.name).tag(voice.id)
                    }
                }
                Button("Preview") {
                    appState.speak("Hi, I'm AK Assistant. Ask me anything.")
                }
            }
        }
    }
}

struct PermissionRow: View {
    let title: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(granted ? .green : .orange)
            Text(title)
            Spacer()
            if !granted {
                Button("Grant…", action: action)
            }
        }
    }
}
