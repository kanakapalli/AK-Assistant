import SwiftUI
import ServiceManagement
import KeyboardShortcuts

/// The pages of Settings, picked with the bar at the top.
enum SettingsTab: String, CaseIterable, Identifiable {
    case dictation, assistant, meetings, grammar, models, general, permissions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dictation: return "Dictation"
        case .assistant: return "AI Assistant"
        case .meetings: return "Meetings"
        case .grammar: return "Grammar"
        case .models: return "Models"
        case .general: return "General"
        case .permissions: return "Permissions"
        }
    }

    var symbol: String {
        switch self {
        case .dictation: return "waveform"
        case .assistant: return "sparkles"
        case .meetings: return "person.2.wave.2"
        case .grammar: return "text.badge.checkmark"
        case .models: return "cpu"
        case .general: return "gearshape"
        case .permissions: return "lock.shield"
        }
    }

    /// One line under the bar saying what the page covers.
    var summary: String {
        switch self {
        case .dictation: return "The push-to-talk key, how your speech becomes text, and how it's pasted."
        case .assistant: return "The AI key, how answers come back, Mac commands, and smart search."
        case .meetings: return "Recording, the transcript and speakers, notes, and storage for meetings."
        case .grammar: return "Shortcuts that fix or rewrite text in any field (email, professional, rude, your own) and their prompts."
        case .models: return "Which model each feature uses, where it runs (GPU, Neural Engine or CPU), downloads, and custom models."
        case .general: return "Startup, sounds and history."
        case .permissions: return "What macOS lets Duck Keyboard do, and a check for the hotkeys."
        }
    }
}

struct SettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        // The page lives in AppState so Learn and Meetings can open Settings on the right page.
        @Bindable var appState = appState

        VStack(spacing: 0) {
            VStack(spacing: 12) {
                // No ScrollView here: a scroll view at the top of this page made the window's
                // sidebar slide up when Settings opened. If the bar doesn't fit, use a menu instead.
                ViewThatFits(in: .horizontal) {
                    DuckTabBar(tabs: SettingsTab.allCases, selection: $appState.settingsTab,
                               title: { $0.title }, symbol: { $0.symbol })
                    Picker("Settings page", selection: $appState.settingsTab) {
                        ForEach(SettingsTab.allCases) { tab in
                            Label(tab.title, systemImage: tab.symbol).tag(tab)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity)

                PageHeader(title: appState.settingsTab.title,
                           subtitle: appState.settingsTab.summary,
                           symbol: appState.settingsTab.symbol)
                    .padding(.horizontal, 20)
                    .frame(maxWidth: 760)
                    .animation(nil, value: appState.settingsTab)
            }
            .padding(.top, 10)
            .padding(.bottom, 12)

            Divider()

            Group {
                switch appState.settingsTab {
                case .dictation: DictationSettings()
                case .assistant: AssistantSettings()
                case .meetings: Form { MeetingSettingsSections() }.formStyle(.grouped)
                case .grammar: GrammarSettings()
                case .models: ModelsSettings()
                case .general: GeneralSettings()
                case .permissions: PermissionsSettings()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Settings")
    }
}

// MARK: - Dictation

private struct DictationSettings: View {
    @Environment(Preferences.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences

        Form {
            Section("Push-to-talk") {
                HotkeyPicker(action: .dictate)
                SettingCaption("Hold the key to record. Release it to transcribe and paste. Press Esc while holding to cancel.")
            }

            ModelLinkSection(features: [.dictation])

            Section("Speech to text") {
                Picker("Language", selection: $preferences.language) {
                    ForEach(Preferences.languages, id: \.code) { lang in
                        Text(lang.name).tag(lang.code)
                    }
                }
                Toggle("Show what I'm saying while I talk", isOn: $preferences.showLiveTranscript)
                Toggle("Remove filler words (um, uh)", isOn: $preferences.removeFillers)
            }

            Section("Microphone") {
                Toggle("Mute the Mac's sound while I'm talking", isOn: $preferences.muteWhileDictating)
                SettingCaption("While you hold a hotkey, videos, music and calls are muted so they can't get into the microphone. The sound comes straight back when you let go.")
                Toggle("Only hear my voice, not the Mac's speakers", isOn: $preferences.cancelSpeakerEcho)
                SettingCaption("Extra filtering of the Mac's own sound, like FaceTime does. Usually not needed with muting on, and it adds a short delay when you start talking.")
            }

            Section("Pasting") {
                Toggle("Restore my clipboard after pasting", isOn: $preferences.restoreClipboard)
                SettingCaption("Also used by Fix grammar.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - AI assistant

private struct AssistantSettings: View {
    @Environment(Preferences.self) private var preferences
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var preferences = preferences

        Form {
            Section("AI key") {
                HotkeyPicker(action: .assistant)
                SettingCaption("Hold the key and ask a question. Release it and a local AI answers. Follow-up questions within 5 minutes continue the same conversation.")
            }

            ModelLinkSection(features: preferences.assistantEnabled && preferences.replyStyle.speaks ? [.assistant, .readAloud] : [.assistant])

            if preferences.assistantEnabled {
                Section("Answers") {
                    ReplySettings()
                }
            }

            Section("Mac commands") {
                Toggle("Let the AI key control my Mac", isOn: $preferences.macCommandsEnabled)
                SettingCaption("Say things like “open Xcode”, “set a timer for 10 minutes” or “volume 30” to the AI key. Common commands run instantly, even without the AI model.")
                if preferences.macCommandsEnabled {
                    Toggle("Understand commands phrased any way (uses the AI model)", isOn: $preferences.aiCommandsEnabled)
                    SettingCaption("When a request isn't a command Duck Keyboard knows, the AI model can still turn it into one, e.g. “fire up Apple's coding app” or “xcode kholo”.")
                    Toggle("Ask before risky actions", isOn: $preferences.confirmRiskyCommands)
                    SettingCaption("Quitting an app, closing a window or tab, lock, sleep, emptying the Trash, turning off Wi-Fi, restart, shut down and log out. When this is off they run right away; restart, shut down and log out still show macOS's own confirmation.")
                    HStack {
                        Button("See everything you can say") { appState.sidebarSelection = .learn }
                        Button("Automation permissions…") { Shell.openAutomationSettings() }
                            .help("Dark mode and emptying the Trash need permission to control System Events and Finder.")
                    }
                }
            }

            MemorySettingsSection()
        }
        .formStyle(.grouped)
    }
}

// MARK: - Grammar

private struct GrammarSettings: View {
    @Environment(Preferences.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences

        Form {
            Section("Writing tools") {
                Toggle("Rewrite text with shortcuts", isOn: $preferences.grammarFixEnabled)
                SettingCaption("Click into any text field and press an action's shortcut. Duck Keyboard selects all the text (⌘A), copies it (⌘C), rewrites it with the local AI model using that action's prompt, and pastes the result back. Each prompt can be changed.")
                if preferences.grammarFixEnabled {
                    SettingCaption("While an action is on, its shortcut works only for Duck Keyboard, so the app's own command (for example ⌘P Print, ⌘R Reload) won't run. Record a different shortcut, or turn the action off, if you need it.")
                }
            }

            if preferences.grammarFixEnabled {
                ForEach(preferences.textActions) { action in
                    TextActionSection(action: action, update: update, delete: { delete(action) })
                }

                Section {
                    Button {
                        let number = preferences.textActions.filter { !$0.builtIn }.count + 1
                        preferences.textActions.append(TextActionCatalog.newCustom(number: number))
                    } label: {
                        Label("Add custom action", systemImage: "plus")
                    }
                    SettingCaption("Make your own, e.g. “Translate to Hindi”, “Make it shorter” or “Turn into bullet points”. Give it a name, a prompt and a shortcut.")
                }
            }

            ModelLinkSection(features: [.writingTools])

            Section("Clipboard") {
                Toggle("Restore my clipboard afterwards", isOn: $preferences.restoreClipboard)
                SettingCaption("Shared with dictation's “Restore my clipboard after pasting”.")
            }
        }
        .formStyle(.grouped)
    }

    private func update(_ action: TextAction) {
        guard let index = preferences.textActions.firstIndex(where: { $0.id == action.id }) else { return }
        preferences.textActions[index] = action
    }

    private func delete(_ action: TextAction) {
        guard !action.builtIn else { return }
        KeyboardShortcuts.reset(action.shortcutName)
        preferences.textActions.removeAll { $0.id == action.id }
    }
}

/// One writing tool: on/off, name, shortcut and prompt.
private struct TextActionSection: View {
    let action: TextAction
    let update: (TextAction) -> Void
    let delete: () -> Void
    @State private var confirmDelete = false

    var body: some View {
        Section {
            Toggle(isOn: binding(\.enabled)) {
                HStack(spacing: 10) {
                    IconTile(symbol: action.symbol, tint: action.enabled ? Duck.writing : .secondary, size: 26)
                    Text(action.title).font(.headline)
                    if action.enabled {
                        DuckKeycapShortcut(name: action.shortcutName)
                    }
                }
            }
            if action.enabled {
                if !action.builtIn {
                    TextField("Name", text: binding(\.title))
                }
                KeyboardShortcuts.Recorder("Shortcut", name: action.shortcutName)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Prompt")
                    TextEditor(text: binding(\.prompt))
                        .font(.callout)
                        .frame(minHeight: 64, maxHeight: 140)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
                    SettingCaption("Tell the AI how to rewrite the text. It always replies with the rewritten text only.")
                }
                HStack {
                    if let builtIn = TextActionCatalog.BuiltIn(rawValue: action.id) {
                        Button("Reset to default") {
                            var reset = builtIn.defaultAction
                            reset.enabled = action.enabled
                            update(reset)
                            KeyboardShortcuts.reset(action.shortcutName)
                        }
                        .disabled(action.prompt == builtIn.defaultPrompt
                                  && KeyboardShortcuts.getShortcut(for: action.shortcutName) == builtIn.defaultShortcut)
                        .help("Puts back the default prompt and shortcut")
                    } else {
                        Button("Delete action", role: .destructive) { confirmDelete = true }
                    }
                }
            }
        }
        .confirmationDialog("Delete “\(action.title)”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive, action: delete)
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<TextAction, Value>) -> Binding<Value> {
        Binding(
            get: { action[keyPath: keyPath] },
            set: { newValue in
                var changed = action
                changed[keyPath: keyPath] = newValue
                update(changed)
            }
        )
    }
}

// MARK: - Models & general

private struct GeneralSettings: View {
    @Environment(Preferences.self) private var preferences
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        @Bindable var preferences = preferences
        Form {
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

            Section("Models") {
                LabeledContent("Download, delete and assign models") {
                    Button("Open Models") { appState.settingsTab = .models }
                }
                SettingCaption("Everything about models lives in Settings › Models: which model each feature uses, where it runs, disk space, and custom models.")
            }

            Section {
                Button("Run onboarding again") { preferences.onboarded = false }
            }
        }
        .formStyle(.grouped)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

// MARK: - Permissions

private struct PermissionsSettings: View {
    @State private var permissions = PermissionSnapshot()

    var body: some View {
        Form {
            Section("Needed for dictation") {
                PermissionRow(title: "Microphone", granted: permissions.microphone) {
                    Task {
                        if !(await Permissions.requestMicrophone()) { Permissions.openMicrophoneSettings() }
                    }
                }
                PermissionRow(title: "Accessibility (hotkey + paste)", granted: permissions.accessibility) {
                    Permissions.requestAccessibility()
                    Permissions.openAccessibilitySettings()
                }
                PermissionRow(title: "Send keystrokes (paste into other apps)", granted: permissions.sendKeystrokes) {
                    Permissions.requestSendKeystrokes()
                    Permissions.openAccessibilitySettings()
                }
            }

            Section("For hotkeys, the AI and meetings") {
                PermissionRow(title: "Input Monitoring (hotkeys on some Macs)", granted: permissions.inputMonitoring) {
                    Permissions.requestInputMonitoring()
                    Permissions.openInputMonitoringSettings()
                }
                PermissionRow(title: "Automation (Mac commands)", granted: permissions.automation == .granted) {
                    Task {
                        if permissions.automation == .denied {
                            Permissions.openAutomationSettings()
                        } else {
                            _ = await Permissions.automationStatus(ask: true)
                        }
                    }
                }
                PermissionRow(title: "Notifications (timers and reminders)", granted: permissions.notifications == .granted) {
                    Task { _ = await Permissions.requestNotifications() }
                }
                PermissionRow(title: "Screen & System Audio Recording (meeting audio)", granted: permissions.screenCapture) {
                    Permissions.requestScreenCapture()
                    Permissions.openScreenCaptureSettings()
                }
                HStack {
                    SettingCaption("Turned one on in System Settings but it still shows as missing? macOS applies some of them only after Duck Keyboard restarts.")
                    Spacer()
                    Button("Restart") { Permissions.relaunch() }
                        .controlSize(.small)
                }
            }

            Section {
                HotkeyCheck()
            }

            Section("This copy of the app") {
                Text(Permissions.runningAppPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
                SettingCaption("macOS gives permissions to one specific copy of the app. If a row shows as missing even though Duck Keyboard looks switched on in System Settings, that entry belongs to another copy (for example the one Xcode runs versus the one in Applications). Remove Duck Keyboard there with –, then add this copy again with +.")
            }
        }
        .formStyle(.grouped)
        .task {
            // Re-check while this page is visible (the user may grant them in System Settings).
            while !Task.isCancelled {
                permissions = await .current()
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }
}

/// Small grey explanation under a setting.
struct SettingCaption: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
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
                    appState.speak("Hi, I'm Duck Keyboard. Ask me anything.")
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
        HStack(spacing: 10) {
            IconTile(symbol: granted ? "checkmark" : "exclamationmark", tint: granted ? Duck.good : Duck.warning, size: 24)
            Text(title)
            Spacer()
            if granted {
                StatusPill(title: "Allowed", tint: Duck.good)
            } else {
                Button("Allow…", action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
    }
}

/// The current shortcut of a writing tool as a keycap (nothing when it has none).
private struct DuckKeycapShortcut: View {
    let name: KeyboardShortcuts.Name

    var body: some View {
        if let shortcut = KeyboardShortcuts.getShortcut(for: name) {
            DuckKeycap(shortcut.description)
        }
    }
}
