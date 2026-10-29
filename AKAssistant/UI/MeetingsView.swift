import SwiftUI
import SwiftData
import AVFoundation
import UniformTypeIdentifiers

/// Recorded meetings: a list on the left, the selected meeting's summary, to-dos and transcript on the right.
struct MeetingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(Preferences.self) private var preferences
    @Query(sort: \Meeting.startedAt, order: .reverse) private var meetings: [Meeting]
    @State private var selection: UUID?
    @State private var search = ""

    private var filtered: [Meeting] {
        guard !search.isEmpty else { return meetings }
        return meetings.filter { meeting in
            meeting.title.localizedCaseInsensitiveContains(search)
                || meeting.summary.localizedCaseInsensitiveContains(search)
                || meeting.transcriptForAI.localizedCaseInsensitiveContains(search)
        }
    }

    private var selected: Meeting? {
        meetings.first { $0.id == selection }
    }

    var body: some View {
        let coordinator = appState.meetings

        HSplitView {
            VStack(spacing: 0) {
                if coordinator.isRecording {
                    RecordingBanner()
                        .padding(10)
                    Divider()
                }
                if filtered.isEmpty {
                    DuckEmptyState(symbol: meetings.isEmpty ? "person.2.wave.2" : "magnifyingglass",
                                   title: meetings.isEmpty ? "No meetings yet" : "No matches",
                                   tint: meetings.isEmpty ? Duck.orange : .secondary)
                } else {
                    List(filtered, selection: $selection) { meeting in
                        MeetingRow(meeting: meeting)
                            .tag(meeting.id)
                    }
                    .listStyle(.inset)
                }
            }
            .frame(minWidth: 230, idealWidth: 280, maxWidth: 380, maxHeight: .infinity)

            Group {
                if let selected {
                    MeetingDetailView(meeting: selected)
                        .id(selected.id)   // fresh tab / player state for each meeting
                } else if meetings.isEmpty {
                    MeetingsEmptyState()
                } else {
                    DuckEmptyState(symbol: "person.2.wave.2", title: "Select a meeting",
                                   message: "Pick a meeting on the left to see its summary, to-dos and transcript.")
                }
            }
            .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Meetings")
        .searchable(text: $search, prompt: "Search meetings")
        .toolbar {
            Button {
                appState.openSettings(.meetings)
            } label: {
                Label("Meeting Settings", systemImage: "slider.horizontal.3")
            }
            .help("Recording, noise, speakers, models and notes settings")

            Button {
                if coordinator.isRecording { appState.stopMeeting() } else { appState.startMeeting() }
            } label: {
                Label(coordinator.isRecording ? "Stop Meeting" : "Start Meeting",
                      systemImage: coordinator.isRecording ? "stop.circle.fill" : "record.circle")
            }
            .help(coordinator.isRecording ? "Stop recording and write the notes"
                  : "Record a meeting (or double-tap \(preferences.hotkey.title))")
        }
        .onAppear {
            if selection == nil { selection = coordinator.activeMeetingID ?? meetings.first?.id }
        }
        // A new meeting just started: show it.
        .onChange(of: coordinator.activeMeetingID) { _, id in
            if let id { selection = id }
        }
    }
}

// MARK: - List

/// Red banner at the top of the list while a meeting is being recorded.
private struct RecordingBanner: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let coordinator = appState.meetings
        HStack(spacing: 10) {
            Image(systemName: "record.circle.fill")
                .foregroundStyle(.red)
                .symbolEffect(.pulse)
            VStack(alignment: .leading, spacing: 2) {
                Text("Recording").font(.headline)
                if let started = coordinator.startedAt {
                    TimelineView(.periodic(from: started, by: 1)) { context in
                        Text(MeetingFormat.clock(context.date.timeIntervalSince(started)))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            LevelBars(level: coordinator.level)
            Button("Stop") { appState.stopMeeting() }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.small)
        }
        .padding(10)
        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct MeetingRow: View {
    @Environment(AppState.self) private var appState
    let meeting: Meeting

    var body: some View {
        let items = meeting.actionItems
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(meeting.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 4)
                MeetingStateBadge(meeting: meeting, compact: true)
            }
            HStack(spacing: 4) {
                Text(meeting.startedAt, format: .dateTime.day().month().hour().minute())
                if meeting.duration > 0 { Text("· \(MeetingFormat.duration(meeting.duration))") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if !meeting.summary.isEmpty {
                Text(meeting.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if !items.isEmpty {
                Label("\(items.filter(\.done).count) of \(items.count) to-dos done", systemImage: "checklist")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

/// "Recording", "Transcribing", "Writing notes", or nothing when done.
private struct MeetingStateBadge: View {
    @Environment(AppState.self) private var appState
    let meeting: Meeting
    var compact = false

    var body: some View {
        let coordinator = appState.meetings
        if coordinator.activeMeetingID == meeting.id {
            badge("Recording", color: .red) {
                Circle().fill(.red).frame(width: 7, height: 7)
            }
        } else if let line = coordinator.progress[meeting.id] {
            badge(compact ? meeting.state.title : line, color: .accentColor) {
                ProgressView().controlSize(.mini)
            }
        }
    }

    private func badge(_ title: String, color: Color, @ViewBuilder icon: () -> some View) -> some View {
        HStack(spacing: 5) {
            icon()
            Text(title).lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.12), in: Capsule())
    }
}

private struct MeetingsEmptyState: View {
    @Environment(AppState.self) private var appState
    @Environment(Preferences.self) private var preferences

    var body: some View {
        DuckEmptyState(symbol: "person.2.wave.2", title: "Record your first meeting",
                       message: "Duck Keyboard writes the transcript, a summary and a to-do list, all on this Mac.") {
            VStack(spacing: 12) {
                Button {
                    appState.startMeeting()
                } label: {
                    Label("Start a meeting", systemImage: "record.circle")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                if preferences.meetingDoubleTap {
                    HStack(spacing: 6) {
                        Text("or double-tap")
                        DuckKeycap(preferences.hotkey.keycapLabel, size: .regular)
                        Text("anywhere")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Detail

private struct MeetingDetailView: View {
    @Environment(AppState.self) private var appState
    let meeting: Meeting

    @State private var tab: DetailTab = .summary
    @State private var player = MeetingPlayer()
    @State private var confirmDelete = false

    enum DetailTab: String, CaseIterable, Identifiable {
        case summary = "Summary"
        case todos = "To-dos"
        case transcript = "Transcript"
        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .summary: return "text.badge.star"
            case .todos: return "checklist"
            case .transcript: return "text.quote"
            }
        }
    }

    var body: some View {
        let coordinator = appState.meetings
        let isLive = coordinator.activeMeetingID == meeting.id
        let todoCount = meeting.actionItems.filter { !$0.done }.count
        // Decoded once here (this view doesn't redraw while audio plays) and handed down.
        let segments = meeting.segments
        let names = meeting.speakerNames
        let audioURL = isLive ? nil : meeting.audioURL

        VStack(alignment: .leading, spacing: 0) {
            header(isLive: isLive, segments: segments, audioURL: audioURL)
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 12)

            if MeetingCoordinator.isMissingModelNote(meeting.note), !isLive {
                NotesModelBanner(meeting: meeting)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            } else if let note = meeting.note {
                Label(note, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }

            if let url = audioURL {
                AudioBar(player: player, url: url)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                    .task(id: url) { player.load(url) }
            }

            DuckTabBar(tabs: DetailTab.allCases, selection: $tab, style: .pills,
                       title: { $0.rawValue }, symbol: { $0.symbol },
                       badge: { $0 == .todos && todoCount > 0 ? "\(todoCount)" : nil })
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

            Divider()

            switch tab {
            case .summary: SummaryTab(meeting: meeting, isLive: isLive)
            case .todos: TodosTab(meeting: meeting)
            case .transcript: TranscriptTab(meeting: meeting, segments: segments, names: names, player: player, isLive: isLive)
            }
        }
        .onAppear { if isLive { tab = .transcript } }
        .onDisappear { player.stop() }
        .confirmationDialog("Delete “\(meeting.title)”?", isPresented: $confirmDelete) {
            Button("Delete Meeting", role: .destructive) { coordinator.delete(meeting) }
        } message: {
            Text("The transcript, notes, to-dos and audio are deleted from this Mac.")
        }
    }

    private func header(isLive: Bool, segments: [TranscriptSegment], audioURL: URL?) -> some View {
        let words = segments.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
        let coordinator = appState.meetings
        let title = Binding(
            get: { meeting.title },
            set: { meeting.title = $0; meeting.hasDefaultTitle = false }
        )
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Meeting title", text: title)
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.semibold))
                HStack(spacing: 4) {
                    Text(meeting.startedAt, format: .dateTime.weekday(.wide).day().month().hour().minute())
                    if isLive, let started = coordinator.startedAt {
                        TimelineView(.periodic(from: started, by: 1)) { context in
                            Text("· \(MeetingFormat.clock(context.date.timeIntervalSince(started)))")
                                .monospacedDigit()
                        }
                    } else if meeting.duration > 0 {
                        Text("· \(MeetingFormat.duration(meeting.duration))")
                    }
                    if words > 0 { Text("· \(words) words") }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Spacer()
            MeetingStateBadge(meeting: meeting)
            if isLive {
                Button("Stop") { appState.stopMeeting() }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }
            Menu {
                Button("Copy Notes") { MeetingActions.copy(meeting.markdown) }
                Button("Export as Markdown…") { MeetingActions.export(meeting) }
                Divider()
                Button(meeting.hasSummary ? "Rewrite Summary and To-dos" : "Write Summary and To-dos") {
                    coordinator.regenerate(meeting)
                }
                .disabled(segments.isEmpty || coordinator.progress[meeting.id] != nil || isLive)
                Button("Redo Clean-up and Speakers") { coordinator.redoCleanup(meeting) }
                    .disabled(!meeting.hasTracks || coordinator.progress[meeting.id] != nil || isLive)
                    .help("Transcribe the kept mic and Mac tracks again, find the speakers, then rewrite the notes.")
                if let url = audioURL {
                    Button("Show Audio in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                Divider()
                Button("Delete Meeting…", role: .destructive) { confirmDelete = true }
                    .disabled(!coordinator.canDelete(meeting))
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }
}

// MARK: Summary

private struct SummaryTab: View {
    @Environment(AppState.self) private var appState
    let meeting: Meeting
    let isLive: Bool

    var body: some View {
        let coordinator = appState.meetings
        let status = coordinator.progress[meeting.id]

        if isLive {
            ContentUnavailableView(
                "Recording…", systemImage: "record.circle",
                description: Text("The summary and to-dos are written when the meeting ends. The transcript fills in as you go.")
            )
        } else if !meeting.hasSummary {
            if let status {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(status).foregroundStyle(.secondary)
                    Text("This runs on your Mac and can take a minute for long meetings.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label("No summary yet", systemImage: "text.badge.star")
                } description: {
                    Text(meeting.segments.isEmpty ? "There's no transcript to summarise." : "Let the local AI write a summary, key points, decisions and to-dos.")
                } actions: {
                    if !meeting.segments.isEmpty {
                        Button("Write Summary and To-dos") { coordinator.regenerate(meeting) }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let status {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(status).foregroundStyle(.secondary)
                        }
                    }
                    if !meeting.summary.isEmpty {
                        NotesSection(title: "Summary", symbol: "text.alignleft") {
                            Text(meeting.summary)
                                .lineSpacing(3)
                                .textSelection(.enabled)
                        }
                    }
                    if !meeting.keyPoints.isEmpty {
                        NotesSection(title: "Key points", symbol: "list.bullet") {
                            BulletList(items: meeting.keyPoints)
                        }
                    }
                    if !meeting.decisions.isEmpty {
                        NotesSection(title: "Decisions", symbol: "checkmark.seal") {
                            BulletList(items: meeting.decisions)
                        }
                    }
                    if !meeting.actionItems.isEmpty {
                        NotesSection(title: "Action items", symbol: "checklist") {
                            BulletList(items: meeting.actionItems.map { item in
                                var line = (item.done ? "✓ " : "") + item.text
                                if let owner = item.owner { line += " — \(owner)" }
                                if let due = item.due { line += " (due \(due))" }
                                return line
                            })
                        }
                    }
                    if let model = meeting.summaryModelName {
                        Text("Written by \(model) on this Mac. AI notes can miss or misread things — check the transcript.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: 720, alignment: .leading)
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct NotesSection<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                IconTile(symbol: symbol, size: 24)
                Text(title).font(.system(.headline, design: .rounded))
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .duckCard(padding: 16)
    }
}

private struct BulletList: View {
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle().fill(Duck.orange).frame(width: 5, height: 5).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 1 }
                    Text(item).textSelection(.enabled)
                }
            }
        }
    }
}

// MARK: To-dos

private struct TodosTab: View {
    let meeting: Meeting
    @State private var newItem = ""

    var body: some View {
        let items = meeting.actionItems
        VStack(spacing: 0) {
            HStack {
                Text(items.isEmpty ? "No to-dos yet" : "\(items.filter(\.done).count) of \(items.count) done")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy To-dos") {
                    MeetingActions.copy(items.map { "- [\($0.done ? "x" : " ")] \($0.text)" }.joined(separator: "\n"))
                }
                .disabled(items.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            List {
                ForEach(items) { item in
                    TodoRow(item: item,
                            update: { change in update(item.id, change) },
                            delete: { remove(item.id) })
                }
                HStack {
                    Image(systemName: "plus.circle")
                        .foregroundStyle(.secondary)
                    TextField("Add a to-do", text: $newItem)
                        .textFieldStyle(.plain)
                        .onSubmit(add)
                    if !newItem.isEmpty {
                        Button("Add", action: add)
                    }
                }
                .padding(.vertical, 4)
            }
            .listStyle(.inset)
        }
    }

    private func update(_ id: UUID, _ change: (inout ActionItem) -> Void) {
        var items = meeting.actionItems
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
        meeting.actionItems = items
    }

    private func remove(_ id: UUID) {
        meeting.actionItems = meeting.actionItems.filter { $0.id != id }
    }

    private func add() {
        let text = newItem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        meeting.actionItems = meeting.actionItems + [ActionItem(text: text)]
        newItem = ""
    }
}

private struct TodoRow: View {
    let item: ActionItem
    let update: ((inout ActionItem) -> Void) -> Void
    let delete: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Toggle("Done", isOn: Binding(get: { item.done }, set: { value in update { $0.done = value } }))
                .toggleStyle(.checkbox)
                .labelsHidden()
            VStack(alignment: .leading, spacing: 3) {
                TextField("To-do", text: Binding(get: { item.text }, set: { value in update { $0.text = value } }))
                    .textFieldStyle(.plain)
                    .help(item.text)
                    .strikethrough(item.done)
                    .foregroundStyle(item.done ? .secondary : .primary)
                if item.owner != nil || item.due != nil {
                    HStack(spacing: 10) {
                        if let owner = item.owner { Label(owner, systemImage: "person") }
                        if let due = item.due { Label(due, systemImage: "calendar") }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(action: delete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Delete to-do")
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button("Copy") { MeetingActions.copy(item.text) }
            Button("Delete", role: .destructive, action: delete)
        }
    }
}

// MARK: Transcript

private struct TranscriptTab: View {
    @Environment(Preferences.self) private var preferences
    let meeting: Meeting
    let segments: [TranscriptSegment]
    let names: [String: String]
    let player: MeetingPlayer
    let isLive: Bool
    @State private var filter = ""

    private func name(_ id: String?) -> String? {
        guard let id else { return nil }
        return names[id] ?? MeetingSpeakers.defaultName(for: id)
    }

    var body: some View {
        let shown = filter.isEmpty ? segments : segments.filter { segment in
            segment.text.localizedCaseInsensitiveContains(filter)
                || (name(segment.speaker) ?? "").localizedCaseInsensitiveContains(filter)
        }
        // Only the playing line changes while audio plays; the rows are Equatable, so the others don't redraw.
        let currentID: UUID? = player.isPlaying
            ? segments.first { player.currentTime >= $0.start && player.currentTime < $0.end }?.id
            : nil
        let canPlay = player.isLoaded

        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find in transcript", text: $filter)
                    .textFieldStyle(.plain)
                Spacer()
                if !segments.isEmpty && !isLive {
                    Label(meeting.transcriptCleaned ? "Cleaned up" : "Live transcript",
                          systemImage: meeting.transcriptCleaned ? "sparkles" : "waveform")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(meeting.transcriptCleaned
                              ? "Redone after the meeting from the separate mic and Mac tracks."
                              : "Written while the meeting was going. Turn on Settings › Meetings › Clean up the transcript for a cleaner one with speakers.")
                }
                Button("Copy Transcript") { MeetingActions.copy(meeting.plainTranscript) }
                    .disabled(segments.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            if !isLive {
                SpeakersBar(meeting: meeting, segments: segments, names: names)
            }
            Divider()

            if segments.isEmpty && !isLive {
                ContentUnavailableView("No transcript", systemImage: "text.quote",
                                       description: Text("Nothing was transcribed for this meeting."))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(shown) { segment in
                                SegmentRow(segment: segment, speaker: name(segment.speaker),
                                           color: SpeakerPalette.color(for: segment.speaker),
                                           isCurrent: segment.id == currentID, canPlay: canPlay,
                                           play: { player.play(from: segment.start) })
                                    .equatable()
                                    .id(segment.id)
                            }
                            if isLive {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text(preferences.meetingLiveTranscript || !preferences.meetingCleanupPass
                                         ? "Listening… new lines appear every 15–30 seconds."
                                         : "Recording… the transcript is written when the meeting ends (live transcript is off in Settings).")
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 8)
                                .id("live")
                            }
                        }
                        .padding(20)
                        .frame(maxWidth: 820, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: segments.count) {
                        guard isLive, filter.isEmpty else { return }
                        withAnimation { proxy.scrollTo("live", anchor: .bottom) }
                    }
                    .onAppear {
                        if isLive { proxy.scrollTo("live", anchor: .bottom) }
                    }
                }
            }
        }
    }
}

/// One transcript paragraph. Equatable so playback only redraws the line being played.
/// (Not text-selectable: selectable text in long lists is very slow on macOS. Use the context menu
/// or Copy Transcript.)
private struct SegmentRow: View, Equatable {
    let segment: TranscriptSegment
    let speaker: String?
    let color: Color
    let isCurrent: Bool
    let canPlay: Bool
    let play: () -> Void

    static func == (lhs: SegmentRow, rhs: SegmentRow) -> Bool {
        lhs.segment == rhs.segment && lhs.speaker == rhs.speaker && lhs.color == rhs.color
            && lhs.isCurrent == rhs.isCurrent && lhs.canPlay == rhs.canPlay
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Button(MeetingFormat.clock(segment.start), action: play)
                .buttonStyle(.link)
                .font(.caption.monospacedDigit())
                .disabled(!canPlay)
                .help(canPlay ? "Play from here" : "No audio was kept for this meeting")
                .frame(width: 58, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                if let speaker {
                    Text(speaker)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(color)
                }
                Text(segment.text)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(isCurrent ? Color.accentColor.opacity(0.12) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .contextMenu {
            Button("Copy Line") {
                MeetingActions.copy(speaker.map { "\($0): \(segment.text)" } ?? segment.text)
            }
            if canPlay {
                Button("Play from Here", action: play)
            }
        }
    }
}

// MARK: - Speakers

/// One colour per speaker, the same everywhere in a meeting.
enum SpeakerPalette {
    private static let colors: [Color] = [.orange, .green, .purple, .pink, .teal, .brown, .indigo, .mint, .cyan, .red]

    static func color(for id: String?) -> Color {
        guard let id else { return .secondary }
        switch id {
        case MeetingSpeakers.you: return .blue
        case MeetingSpeakers.others: return .gray
        default:
            let number = Int(id.dropFirst()) ?? 1
            return colors[(max(1, number) - 1) % colors.count]
        }
    }
}

/// The speakers in a meeting with how long each talked. Click one to rename it.
private struct SpeakersBar: View {
    let meeting: Meeting
    let segments: [TranscriptSegment]
    let names: [String: String]

    /// Speakers in order of first appearance, with how long each talked.
    static func stats(_ segments: [TranscriptSegment]) -> [SpeakerStat] {
        var order: [String] = []
        var seconds: [String: Double] = [:]
        for segment in segments {
            guard let id = segment.speaker else { continue }
            if seconds[id] == nil { order.append(id) }
            seconds[id, default: 0] += segment.end - segment.start
        }
        return order.map { SpeakerStat(id: $0, seconds: seconds[$0] ?? 0) }
    }

    var body: some View {
        let stats = Self.stats(segments)
        if !stats.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(stats) { stat in
                        SpeakerChip(meeting: meeting, stat: stat,
                                    name: names[stat.id] ?? MeetingSpeakers.defaultName(for: stat.id))
                    }
                    Text("Click a speaker to name them")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
            }
        }
    }
}

private struct SpeakerChip: View {
    let meeting: Meeting
    let stat: SpeakerStat
    let name: String
    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        let color = SpeakerPalette.color(for: stat.id)
        Button {
            draft = name
            editing = true
        } label: {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(name)
                Text(MeetingFormat.duration(stat.seconds))
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(color.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Rename this speaker")
        .popover(isPresented: $editing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Rename speaker").font(.headline)
                TextField("Name", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                    .onSubmit(save)
                Text("Updates the transcript, summary and to-dos.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel") { editing = false }
                    Button("Rename", action: save)
                        .keyboardShortcut(.defaultAction)
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(14)
        }
    }

    private func save() {
        meeting.renameSpeaker(stat.id, to: draft)
        editing = false
    }
}

// MARK: - Audio playback

private struct AudioBar: View {
    let player: MeetingPlayer
    let url: URL

    var body: some View {
        HStack(spacing: 10) {
            Button {
                player.toggle()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 16)
            }
            .buttonStyle(.borderless)
            .disabled(!player.isLoaded)
            .help(player.isPlaying ? "Pause" : "Play recording")

            Text(MeetingFormat.clock(player.currentTime))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Slider(value: Binding(get: { player.currentTime }, set: { player.seek(to: $0) }),
                   in: 0...max(player.duration, 1))
                .controlSize(.small)
            Text(MeetingFormat.clock(player.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Plays a meeting's audio and reports the position for the transcript highlight.
@MainActor
@Observable
final class MeetingPlayer {
    private(set) var isPlaying = false
    private(set) var isLoaded = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var ticker: Task<Void, Never>?

    @ObservationIgnored private var loadingURL: URL?

    /// Opens the file off the main thread (a long or unfinished file can take a moment to parse).
    func load(_ url: URL) {
        guard player?.url != url, loadingURL != url else { return }
        stop()
        loadingURL = url
        Task { [weak self] in
            let loaded = await Task.detached(priority: .userInitiated) { () -> AVAudioPlayer? in
                guard let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
                player.prepareToPlay()
                return player
            }.value
            guard let self, self.loadingURL == url else { return }
            self.loadingURL = nil
            self.player = loaded
            self.duration = loaded?.duration ?? 0
            self.isLoaded = loaded != nil
            self.currentTime = 0
        }
    }

    func toggle() {
        isPlaying ? pause() : play()
    }

    func play(from time: Double? = nil) {
        guard let player else { return }
        if let time {
            player.currentTime = max(0, min(time, player.duration))
            currentTime = player.currentTime
        }
        player.play()
        isPlaying = true
        startTicker()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        ticker?.cancel()
    }

    func stop() {
        player?.stop()
        isPlaying = false
        ticker?.cancel()
    }

    func seek(to time: Double) {
        player?.currentTime = time
        currentTime = time
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
                if !player.isPlaying {
                    self.isPlaying = false
                    return
                }
            }
        }
    }
}

// MARK: - Actions

private enum MeetingActions {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @MainActor
    static func export(_ meeting: Meeting) {
        let panel = NSSavePanel()
        let safeTitle = meeting.title.replacingOccurrences(of: #"[/:\\]"#, with: "-", options: .regularExpression)
        panel.nameFieldStringValue = safeTitle + ".md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? meeting.markdown.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Notes model missing

/// Shown when a meeting ended before an AI model was downloaded: download it right here, watch the
/// progress, and the summary and to-dos are written as soon as it's ready.
private struct NotesModelBanner: View {
    let meeting: Meeting

    @Environment(AppState.self) private var appState
    @Environment(ModelManager.self) private var modelManager

    var body: some View {
        let coordinator = appState.meetings
        let model = coordinator.notesModelToDownload
        let state = modelManager.state(of: model)
        let writing = coordinator.progress[meeting.id]

        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "sparkles")
                .font(.title2)
                .foregroundStyle(Duck.assistant)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 4) {
                Text(title(state: state, writing: writing, model: model))
                    .font(.callout.weight(.semibold))
                Text(detail(state: state, writing: writing, model: model))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if case .downloading(let progress) = state {
                    if let progress {
                        ProgressView(value: progress).frame(maxWidth: 260)
                    } else {
                        ProgressView().progressViewStyle(.linear).frame(maxWidth: 260)
                    }
                } else if writing != nil {
                    ProgressView().progressViewStyle(.linear).frame(maxWidth: 260)
                }
            }

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                switch state {
                case .notDownloaded, .failed:
                    Button("Choose model…") {
                        appState.modelsFocus = .meetingNotes
                        appState.openSettings(.models)
                    }
                    .help("Pick a different AI model for meeting notes in Settings › Models")
                    Button(stateIsFailed(state) ? "Try again" : "Download") {
                        coordinator.downloadNotesModelAndSummarize(meeting)
                    }
                    .buttonStyle(.borderedProminent)
                case .downloading:
                    EmptyView()
                case .downloaded:
                    if writing == nil {
                        Button("Write notes") { coordinator.regenerate(meeting) }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .controlSize(.regular)
            .fixedSize()
        }
        .padding(12)
        .background(Duck.assistant.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func stateIsFailed(_ state: ModelManager.State) -> Bool {
        if case .failed = state { return true }
        return false
    }

    private func title(state: ModelManager.State, writing: String?, model: ChatModel) -> String {
        if writing != nil { return "Writing the summary and to-dos…" }
        switch state {
        case .notDownloaded: return "No summary yet: an AI model is needed"
        case .downloading(let progress):
            if let progress { return "Downloading \(model.name)… \(Int(progress * 100))%" }
            return "Downloading \(model.name)…"
        case .downloaded: return "\(model.name) is ready"
        case .failed: return "Download failed"
        }
    }

    private func detail(state: ModelManager.State, writing: String?, model: ChatModel) -> String {
        if let writing { return writing }
        switch state {
        case .notDownloaded:
            return "Download \(model.name) (\(model.sizeLabel)) once and Duck Keyboard writes the summary, key points, decisions and to-dos for this meeting. It runs on this Mac."
        case .downloading:
            return "The notes are written as soon as the download finishes. You can leave this page."
        case .downloaded:
            return "Write the summary and to-dos for this meeting now."
        case .failed(let message):
            return message
        }
    }
}
