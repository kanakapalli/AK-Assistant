import SwiftUI
import KeyboardShortcuts

struct TranslationSettings: View {
    @Environment(Preferences.self) private var preferences
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var preferences = preferences

        Form {
            Section("Translation mode") {
                Toggle("Enable translation", isOn: $preferences.translationEnabled)
                SettingCaption("When on, the dictation key transcribes what you say and translates it instead of pasting. A text-selection shortcut (⌘⌥T) also appears in any field.")

                if preferences.translationEnabled {
                    Picker("Translate to", selection: $preferences.translationTargetLanguage) {
                        ForEach(Preferences.translationLanguages, id: \.code) { lang in
                            Text(lang.name).tag(lang.code)
                        }
                    }

                    Toggle("Read translation aloud", isOn: $preferences.translationReadAloud)
                    SettingCaption("After translating, the voice model reads the result out. Needs a voice model downloaded in Settings › Models.")
                }
            }

            if preferences.translationEnabled {
                Section("Text selection shortcut") {
                    KeyboardShortcuts.Recorder("Translate selection", name: .translateSelection)
                    SettingCaption("Select text in any app and press this to translate it to \(preferences.translationTargetLanguageName). The translation appears in the Dynamic Island.")
                }

                ModelLinkSection(features: preferences.translationReadAloud ? [.assistant, .readAloud] : [.assistant])
            }

            Section("Live translation (extended)") {
                Toggle("Live system audio translation", isOn: $preferences.liveAudioTranslationEnabled)
                SettingCaption("Captures everything the Mac plays and translates it to \(preferences.translationTargetLanguageName) in real time — reading the translation aloud. Two people speaking different languages can have a conversation using this feature.")

                if preferences.liveAudioTranslationEnabled {
                    if appState.isLiveTranslating {
                        HStack(spacing: 8) {
                            Image(systemName: "character.bubble.fill")
                                .foregroundStyle(.cyan)
                                .symbolEffect(.pulse)
                            Text("Live translation is active")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Stop") {
                                Task { await appState.stopLiveAudioTranslation() }
                            }
                            .buttonStyle(.bordered)
                        }
                    } else {
                        HStack(spacing: 8) {
                            Button("Start live translation") {
                                Task { await appState.startLiveAudioTranslation() }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }

                    if !Permissions.screenCaptureGranted {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Screen Recording permission required")
                                    .font(.callout.weight(.medium))
                                Text("Live translation captures the Mac's audio output, which needs the Screen & System Audio Recording permission.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Open Settings…") { Permissions.openScreenCaptureSettings() }
                                .buttonStyle(.bordered)
                        }
                        .padding(10)
                        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                    }

                    SettingCaption("The translation is spoken aloud, so make sure the target device (speaker or headphones) is set up for the person listening. Duck Keyboard's own voice output is excluded from the capture to prevent feedback loops.")
                }
            }
        }
        .formStyle(.grouped)
    }
}
