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
        switch appState.status {
        case .recording: return "Listening…"
        case .transcribing: return "Transcribing…"
        default: return "Hold \(preferences.hotkey.title) to dictate · \(preferences.selectedModel.name)"
        }
    }

    private var assistantLine: String {
        "Hold \(preferences.assistantHotkey.title) to ask AI · \(preferences.chatModel.name)"
    }

    private func preview(_ text: String) -> String {
        text.count > 60 ? String(text.prefix(57)) + "…" : text
    }
}
