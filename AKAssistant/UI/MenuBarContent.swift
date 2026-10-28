import SwiftUI
import SwiftData

/// The panel under the menu bar icon: status, how to use the keys, meeting control,
/// recent entries (click to copy), timers, and shortcuts into the app.
struct MenuBarContent: View {
    @Environment(AppState.self) private var appState
    @Environment(Preferences.self) private var preferences
    @Environment(\.openWindow) private var openWindow

    @Query(sort: \DictationRecord.createdAt, order: .reverse) private var records: [DictationRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 12)

            VStack(alignment: .leading, spacing: 12) {
                keysCard
                meetingCard
                if preferences.assistantEnabled && (appState.isSpeaking || appState.reply != nil) {
                    assistantRow
                }
                timersSection
                recentSection
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)

            Divider()
            footer
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
        }
        .frame(width: 340)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            BrandMark(size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text("Duck Keyboard")
                    .font(.system(.headline, design: .rounded).weight(.bold))
                Text(preferences.selectedModel.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            StatusPill(title: status.title, tint: status.tint)
        }
    }

    private var status: (title: String, tint: Color) {
        if appState.meetings.isRecording { return ("Meeting", Duck.recording) }
        switch appState.status {
        case .recording: return ("Listening", Duck.orange)
        case .transcribing: return ("Working", Duck.orange)
        case .error: return ("Problem", Duck.warning)
        default:
            if !Permissions.accessibilityGranted { return ("Needs access", Duck.warning) }
            return appState.isSpeaking ? ("Speaking", Duck.assistant) : ("Ready", Duck.good)
        }
    }

    // MARK: Keys

    private var keysCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            keyLine(preferences.hotkey, verb: "to dictate", symbol: "waveform", tint: Duck.dictation)
            if preferences.assistantEnabled, preferences.assistantHotkey != .off {
                keyLine(preferences.assistantHotkey, verb: "to ask AI", symbol: "sparkles", tint: Duck.assistant)
            }
            if !Permissions.accessibilityGranted {
                Button {
                    open { appState.openSettings(.permissions) }
                } label: {
                    Label("Allow Accessibility so the keys work", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Duck.warning)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .duckCard(padding: 10)
    }

    private func keyLine(_ key: HotkeyChoice, verb: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            IconTile(symbol: symbol, tint: tint, size: 22)
            Text("Hold").foregroundStyle(.secondary)
            DuckKeycap(key.keycapLabel)
                .help(key.title)
            Text(verb).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .font(.callout)
    }

    // MARK: Meeting

    @ViewBuilder private var meetingCard: some View {
        let coordinator = appState.meetings
        if coordinator.isRecording {
            HStack(spacing: 10) {
                Image(systemName: "record.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Duck.recording)
                    .symbolEffect(.pulse)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Recording a meeting").font(.callout.weight(.semibold))
                    if let started = coordinator.startedAt {
                        TimelineView(.periodic(from: started, by: 1)) { context in
                            Text(MeetingFormat.clock(context.date.timeIntervalSince(started)))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 4)
                LevelBars(level: coordinator.level)
                Button("Stop") { appState.stopMeeting() }
                    .buttonStyle(.borderedProminent)
                    .tint(Duck.recording)
                    .controlSize(.small)
            }
            .duckCard(tint: Duck.recording, padding: 10)
        } else {
            HStack(spacing: 8) {
                Button {
                    appState.startMeeting()
                } label: {
                    Label("Record a meeting", systemImage: "record.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .help(preferences.meetingDoubleTap ? "Or double-tap \(preferences.hotkey.title)" : "Transcript, summary and to-dos, all on this Mac")

                Button {
                    open { appState.showMeetings() }
                } label: {
                    Image(systemName: "person.2.wave.2")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .help("Open your meetings")
            }
        }
    }

    // MARK: AI

    private var assistantRow: some View {
        HStack(spacing: 8) {
            if appState.isSpeaking {
                Button {
                    appState.stopSpeaking()
                } label: {
                    Label("Stop speaking", systemImage: "speaker.slash.fill")
                }
            }
            Button {
                appState.newConversation()
            } label: {
                Label("New AI conversation", systemImage: "plus.bubble")
            }
            Spacer(minLength: 0)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    // MARK: Timers

    @ViewBuilder private var timersSection: some View {
        let timers = appState.timers.timers
        if !timers.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    SectionLabel("Timers")
                    Spacer()
                    if timers.count > 1 {
                        Button("Cancel all") { appState.timers.cancelAll() }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundStyle(Duck.orange)
                    }
                }
                ForEach(timers) { timer in
                    HStack(spacing: 8) {
                        IconTile(symbol: timer.isReminder ? "bell.fill" : "timer", tint: Duck.orange, size: 22)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(timer.isReminder ? timer.label : "\(DurationText.spoken(timer.length ?? 0)) timer")
                                .font(.callout)
                                .lineLimit(1)
                            Text(timer.fireDate, style: .timer)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Button {
                            appState.timers.cancel(timer.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Cancel")
                    }
                }
            }
        }
    }

    // MARK: Recent

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionLabel("Recent")
                Spacer()
                if !records.isEmpty {
                    Text("Click to copy")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            if records.isEmpty {
                HStack(spacing: 6) {
                    Text("Nothing yet. Hold")
                    DuckKeycap(preferences.hotkey.keycapLabel)
                    Text("in any text field and speak.")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.vertical, 6)
            } else {
                VStack(spacing: 2) {
                    ForEach(Array(records.prefix(4))) { record in
                        RecentRow(record: record)
                    }
                }
                .padding(.horizontal, -6)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 2) {
            FooterButton(title: "Open Duck Keyboard", symbol: "macwindow") {
                open { }
            }
            .keyboardShortcut("o")
            Spacer(minLength: 0)
            FooterIconButton(symbol: "clock.arrow.circlepath", help: "History") {
                open { appState.sidebarSelection = .history }
            }
            FooterIconButton(symbol: "graduationcap", help: "Learn what Duck Keyboard can do") {
                open { appState.sidebarSelection = .learn }
            }
            FooterIconButton(symbol: "gearshape", help: "Settings") {
                open { appState.sidebarSelection = .settings }
            }
            FooterIconButton(symbol: "power", help: "Quit Duck Keyboard") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }

    /// Picks the page, closes this panel and brings up the main window.
    private func open(_ choosePage: () -> Void) {
        choosePage()
        MenuBarPanel.close()
        openWindow(id: WindowID.main)
        NSApp.activate()
    }
}

/// Closes the menu bar panel after an action that opens the main window.
@MainActor
enum MenuBarPanel {
    static func close() {
        for window in NSApp.windows where String(describing: type(of: window)).contains("MenuBarExtra") {
            window.close()
        }
    }
}

/// One recent entry: kind icon, the text, time. Click copies (the answer for AI, the result for rewrites).
private struct RecentRow: View {
    let record: DictationRecord
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        let kind = HistoryKind(record)
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(record.answer ?? record.text, forType: .string)
            withAnimation(.snappy) { copied = true }
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                withAnimation(.snappy) { copied = false }
            }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                IconTile(symbol: kind.symbol, tint: kind.tint, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(record.text)
                        .font(.callout)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(.primary)
                    HStack(spacing: 4) {
                        Text(record.createdAt, format: .relative(presentation: .named))
                        if let app = record.appName, !app.isEmpty {
                            Text("·")
                            Text(app).lineLimit(1)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                    .font(.caption)
                    .foregroundStyle(copied ? Duck.good : Color.secondary)
                    .opacity(hovering || copied ? 1 : 0)
                    .padding(.top, 3)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering ? Duck.orange.opacity(0.10) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(kind == .dictation ? "Copy" : kind == .assistant ? "Copy the answer" : "Copy the rewritten text")
    }
}

private struct FooterButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                Text(title)
                Text("⌘O").font(.caption).foregroundStyle(.tertiary)
            }
            .font(.callout.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? Color.primary.opacity(0.08) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct FooterIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(hovering ? Color.primary : Color.secondary)
                .frame(width: 28, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? Color.primary.opacity(0.08) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}
