import SwiftUI
import SwiftData

/// The dropdown under the menu bar icon.
struct MenuBarContent: View {
    @Environment(AppState.self) private var appState
    @Environment(Preferences.self) private var preferences
    @Environment(\.openWindow) private var openWindow

    @Query(sort: \DictationRecord.createdAt, order: .reverse) private var records: [DictationRecord]

    var body: some View {
        Text(statusLine)
        if preferences.assistantEnabled {
            Text(assistantLine)
        }

        Divider()

        if appState.meetings.isRecording {
            Button("Stop meeting recording") { appState.stopMeeting() }
        } else {
            Button(preferences.meetingDoubleTap ? "Start meeting recording (double-tap \(preferences.hotkey.shortTitle))" : "Start meeting recording") {
                appState.startMeeting()
            }
        }
        Button("Meetings…") {
            appState.showMeetings()
            openWindow(id: WindowID.main)
            NSApp.activate()
        }

        Divider()

        if records.isEmpty {
            Text("No dictations yet")
        } else {
            Text("Recent — click to copy")
            ForEach(Array(records.prefix(5))) { record in
                Button(preview(record.text)) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(record.text, forType: .string)
                }
            }
        }

        Divider()

        if preferences.assistantEnabled {
            if appState.isSpeaking {
                Button("Stop speaking") { appState.stopSpeaking() }
            }
            Button("New AI conversation") { appState.newConversation() }
            Divider()
        }

        let timers = appState.timers.timers
        if !timers.isEmpty {
            Text("Timers — click to cancel")
            ForEach(timers) { timer in
                Button(timerLine(timer)) { appState.timers.cancel(timer.id) }
            }
            if timers.count > 1 {
                Button("Cancel all timers") { appState.timers.cancelAll() }
            }
            Divider()
        }

        Button("Learn what AK Assistant can do") {
            appState.sidebarSelection = .learn
            openWindow(id: WindowID.main)
            NSApp.activate()
        }

        Button("Open AK Assistant") {
            openWindow(id: WindowID.main)
            NSApp.activate()
        }
        .keyboardShortcut("o")

        Divider()

        Button("Quit AK Assistant") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var statusLine: String {
        if appState.meetings.isRecording { return "Recording a meeting…" }
        switch appState.status {
        case .recording: return "Listening…"
        case .transcribing: return "Transcribing…"
        default: return "Hold \(preferences.hotkey.title) to dictate · \(preferences.selectedModel.name)"
        }
    }

    private var assistantLine: String {
        "Hold \(preferences.assistantHotkey.title) to ask AI · \(preferences.chatModel.name)"
    }

    private func timerLine(_ timer: ActiveTimer) -> String {
        let time = timer.fireDate.formatted(date: .omitted, time: .shortened)
        let name = timer.isReminder ? timer.label : "\(DurationText.spoken(timer.length ?? 0)) timer"
        return "\(name) · \(time)"
    }

    private func preview(_ text: String) -> String {
        text.count > 60 ? String(text.prefix(57)) + "…" : text
    }
}
