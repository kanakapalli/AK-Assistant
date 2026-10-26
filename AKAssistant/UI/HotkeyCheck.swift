import SwiftUI

/// Settings › Permissions › Hotkey check: everything that decides whether holding a key works,
/// updated live, plus a Reset button. Press your key while this is open to see it arrive.
struct HotkeyCheck: View {
    @Environment(AppState.self) private var appState
    @Environment(Preferences.self) private var preferences
    @State private var inputMonitoring = Permissions.inputMonitoringGranted
    @State private var secureApp: String? = Permissions.secureInputApp
    @State private var otherCopies: [URL] = AppState.otherCopiesRunning
    @State private var diagnostics: (lastEvent: String?, lastEventAt: Date?, keysDown: String, monitors: Int) = (nil, nil, "none", 0)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hotkey check").font(.headline)

            row(ok: Permissions.accessibilityGranted, "Accessibility",
                bad: "Off for this copy: keys in other apps can't be seen.")
            HStack {
                row(ok: inputMonitoring, "Input Monitoring",
                    bad: "Not granted. Usually not needed, but some Macs require it for global keys.")
                if !inputMonitoring {
                    Button("Grant…") {
                        Permissions.requestInputMonitoring()
                        Permissions.openInputMonitoringSettings()
                    }
                }
            }
            row(ok: secureApp == nil, "Secure keyboard entry",
                bad: "\(secureApp ?? "An app") has it on, so macOS hides key presses from other apps. Leave the password field, or turn off Secure Keyboard Entry in Terminal.")
            row(ok: otherCopies.isEmpty, "One copy running",
                bad: "Another copy is running (\(otherCopies.map(\.lastPathComponent).joined(separator: ", "))). Quit it; both react to the same keys.")
            row(ok: !appState.meetings.isRecording, "Not recording a meeting",
                bad: "A meeting is recording: \(preferences.hotkey.title) stops it instead of dictating.")

            Divider()
            LabeledContent("Last key seen") {
                if let text = diagnostics.lastEvent, let at = diagnostics.lastEventAt {
                    Text("\(text) · \(at, style: .relative) ago").monospacedDigit()
                } else {
                    Text("Nothing yet: hold \(preferences.hotkey.title) now").foregroundStyle(.secondary)
                }
            }
            LabeledContent("Keys held / monitors", value: "\(diagnostics.keysDown) / \(diagnostics.monitors)")
            HStack {
                Button("Reset hotkeys") { appState.resetHotkeys() }
                Text("Clears a stuck key or step and re-installs the key monitors.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .task {
            while !Task.isCancelled {
                inputMonitoring = Permissions.inputMonitoringGranted
                secureApp = Permissions.secureInputApp
                otherCopies = AppState.otherCopiesRunning
                diagnostics = appState.hotkeyDiagnostics
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func row(ok: Bool, _ title: String, bad: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if !ok {
                    Text(bad).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
