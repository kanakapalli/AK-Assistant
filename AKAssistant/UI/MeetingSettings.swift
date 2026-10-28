import SwiftUI

/// Everything about meeting mode in Settings: recording, the clean-up pass and speakers, notes, storage.
/// Shown as several sections inside the Settings form.
struct MeetingSettingsSections: View {
    @Environment(Preferences.self) private var preferences
    @Environment(AppState.self) private var appState
    @Environment(ModelManager.self) private var modelManager
    @State private var screenGranted = Permissions.screenCaptureGranted
    @State private var storageUsed: Int64 = 0

    var body: some View {
        @Bindable var preferences = preferences

        // MARK: Recording
        Section("Recording") {
            Toggle("Double-tap \(preferences.hotkey.shortTitle) to record a meeting", isOn: $preferences.meetingDoubleTap)
            Caption("Double-tap the dictation key to start; press it once (or double-tap) to stop. You can also start from the menu bar or the Meetings screen.")

            Toggle("Record the Mac's audio (other people on the call)", isOn: $preferences.meetingCaptureSystemAudio)
            Caption("Captures Zoom, Meet, Teams and other apps even when you wear headphones. Only the audio is used.")
            if preferences.meetingCaptureSystemAudio && !screenGranted {
                HStack {
                    Label("Needs Screen & System Audio Recording permission", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Allow…") {
                        Permissions.requestScreenCapture()
                        Permissions.openScreenCaptureSettings()
                    }
                }
                .font(.callout)
            }

            Toggle("Reduce background noise and echo on my mic", isOn: $preferences.meetingVoiceProcessing)
            Caption("Apple's voice processing, as in FaceTime: removes fan hum, keyboard noise and the call's sound coming back from your speakers.")

            Picker("Meeting language", selection: $preferences.meetingLanguage) {
                Text("Same as dictation (\(languageName(preferences.language)))").tag("same")
                Divider()
                ForEach(Preferences.languages, id: \.code) { language in
                    Text(language.name).tag(language.code)
                }
            }
            Caption("Pinning the language is more accurate than auto-detect. Parakeet models ignore it.")

            Toggle("Show the transcript while the meeting is going", isOn: $preferences.meetingLiveTranscript)
                .disabled(!preferences.meetingCleanupPass)
            Caption(preferences.meetingCleanupPass
                    ? "Off saves battery during long meetings; the transcript is then written when the meeting ends."
                    : "Always on while “Clean up the transcript” is off, otherwise there would be no transcript.")

            Picker("Stop recording automatically after", selection: $preferences.meetingMaxHours) {
                ForEach([1, 2, 4, 8], id: \.self) { hours in
                    Text(hours == 1 ? "1 hour" : "\(hours) hours").tag(hours)
                }
            }
        }

        // MARK: Transcript & speakers
        Section("Transcript & speakers") {
            Toggle("Clean up the transcript after the meeting", isOn: $preferences.meetingCleanupPass)
            Caption("Re-transcribes your mic and the Mac's audio separately, cut at natural pauses, skipping silence and noise. Takes a minute or two for an hour of audio.")

            if preferences.meetingCleanupPass {
                ModelLinkRow(feature: .meetingTranscript)

                Picker("Speech detection", selection: $preferences.meetingSpeechSensitivity) {
                    ForEach(SpeechSensitivity.allCases) { level in
                        Text(level.title).tag(level)
                    }
                }
                Caption("Low ignores more background noise; High catches soft or distant voices but may pick up noise.")

                Toggle("Remove the call's echo from my mic", isOn: $preferences.meetingRemoveEcho)
                Caption("Drops your-mic lines that just repeat what the others said (their voice leaking from your speakers).")

                Toggle("Show who said what (speaker labels)", isOn: $preferences.meetingIdentifySpeakers)
                Caption("Labels lines “You”, “Speaker 1”, “Speaker 2”… with an on-device speaker model (about 30 MB, downloaded the first time). Rename speakers in a meeting's Transcript tab.")

                if preferences.meetingIdentifySpeakers {
                    Picker("People in the meeting", selection: $preferences.meetingSpeakerCount) {
                        Text("Work it out automatically").tag(0)
                        Divider()
                        ForEach(2...10, id: \.self) { count in
                            Text("\(count) people").tag(count)
                        }
                    }
                    Caption("Including you. Setting the exact number helps when two voices sound alike. Leave it on automatic if it changes from meeting to meeting.")
                }
            }
        }

        // MARK: Notes
        Section("Notes") {
            Toggle("Write a summary and to-dos when a meeting ends", isOn: $preferences.meetingWriteNotes)
            Caption("Off: you get the transcript only, and can still write notes from a meeting's ⋯ menu.")

            ModelLinkRow(feature: .meetingNotes)

            Picker("Notes detail", selection: $preferences.meetingNotesDetail) {
                ForEach(NotesDetail.allCases) { detail in
                    Text(detail.title).tag(detail)
                }
            }
            .pickerStyle(.segmented)
            Caption("Brief: a few sentences and the main points. Detailed: a paragraph per topic; slower to write.")
        }

        // MARK: Storage
        Section("Storage") {
            Toggle("Keep meeting audio for playback", isOn: $preferences.meetingKeepAudio)
            Caption("About 15 MB per hour for playback, plus about 30 MB for the separate tracks used by “Redo Clean-up and Speakers”. Off: the audio is deleted once the transcript is done.")
            LabeledContent("Meeting audio on this Mac") {
                Text(ByteCountFormatter.string(fromByteCount: storageUsed, countStyle: .file))
                    .monospacedDigit()
            }
            HStack {
                Button("Show in Finder") { NSWorkspace.shared.open(MeetingStorage.folder) }
                Button("Open Meetings") { appState.sidebarSelection = .meetings }
            }
        }
        .task {
            // Keep the permission row and storage figure current while Settings is open.
            while !Task.isCancelled {
                screenGranted = Permissions.screenCaptureGranted
                storageUsed = await Task.detached { MeetingStorage.bytesUsed() }.value
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func languageName(_ code: String) -> String {
        Preferences.languages.first { $0.code == code }?.name ?? code
    }
}

/// Small grey explanation under a setting.
private struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
