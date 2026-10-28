import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct HistoryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \DictationRecord.createdAt, order: .reverse) private var records: [DictationRecord]
    @State private var search = ""
    @State private var confirmClear = false
    @State private var kind: KindFilter = .all

    enum KindFilter: String, CaseIterable, Identifiable {
        case all = "All", dictation = "Dictation", assistant = "AI", writing = "Writing"
        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .all: return "tray.full"
            case .dictation: return HistoryKind.dictation.symbol
            case .assistant: return HistoryKind.assistant.symbol
            case .writing: return HistoryKind.rewrite.symbol
            }
        }

        var tint: Color {
            switch self {
            case .all: return Duck.orange
            case .dictation: return HistoryKind.dictation.tint
            case .assistant: return HistoryKind.assistant.tint
            case .writing: return HistoryKind.rewrite.tint
            }
        }
    }

    private func count(_ filter: KindFilter) -> Int {
        switch filter {
        case .all: return records.count
        case .dictation: return records.filter(\.isDictation).count
        case .assistant: return records.filter(\.isAssistant).count
        case .writing: return records.filter(\.isRewrite).count
        }
    }

    private var filtered: [DictationRecord] {
        records.filter { record in
            switch kind {
            case .all: break
            case .dictation: if !record.isDictation { return false }
            case .assistant: if !record.isAssistant { return false }
            case .writing: if !record.isRewrite { return false }
            }
            guard !search.isEmpty else { return true }
            return record.text.localizedCaseInsensitiveContains(search)
                || (record.answer ?? "").localizedCaseInsensitiveContains(search)
                || (record.appName ?? "").localizedCaseInsensitiveContains(search)
                || record.rewriteActionTitle.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                StatsHeader(records: records)
                HStack(spacing: 6) {
                    ForEach(KindFilter.allCases) { filter in
                        DuckChip(title: filter.rawValue, symbol: filter.symbol, count: count(filter),
                                 tint: filter.tint, selected: kind == filter) {
                            withAnimation(.snappy(duration: 0.2)) { kind = filter }
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            if filtered.isEmpty {
                if records.isEmpty {
                    HistoryEmptyState()
                } else {
                    DuckEmptyState(symbol: "magnifyingglass", title: "No matches",
                                   message: "Try a different search or filter.", tint: .secondary)
                }
            } else {
                List {
                    ForEach(groupedByDay, id: \.day) { group in
                        Section {
                            ForEach(group.records) { record in
                                row(record)
                                    .listRowSeparator(.hidden)
                                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                            }
                        } header: {
                            HStack(spacing: 6) {
                                Text(dayTitle(group.day))
                                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                                    .foregroundStyle(.primary)
                                Text("\(group.records.count)")
                                    .font(.caption.weight(.semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.top, 6)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("History")
        .searchable(text: $search, prompt: "Search history")
        .toolbar {
            Menu {
                Button("Export as CSV…") { export(csv: true) }
                Button("Export as Text…") { export(csv: false) }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .disabled(records.isEmpty)

            Button(role: .destructive) { confirmClear = true } label: {
                Label("Clear All", systemImage: "trash")
            }
            .disabled(records.isEmpty)
        }
        .confirmationDialog("Delete all history?", isPresented: $confirmClear) {
            Button("Delete All", role: .destructive) { clearAll() }
        }
    }

    /// Entries split by day, newest first: "Today", "Yesterday", "Mon 20 Oct"…
    private var groupedByDay: [(day: Date, records: [DictationRecord])] {
        let calendar = Calendar.current
        var groups: [(day: Date, records: [DictationRecord])] = []
        for record in filtered {   // already newest first
            let day = calendar.startOfDay(for: record.createdAt)
            if let last = groups.last, last.day == day {
                groups[groups.count - 1].records.append(record)
            } else {
                groups.append((day, [record]))
            }
        }
        return groups
    }

    private func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        let sameYear = calendar.isDate(day, equalTo: .now, toGranularity: .year)
        return day.formatted(sameYear ? .dateTime.weekday(.wide).day().month(.wide)
                                      : .dateTime.day().month(.wide).year())
    }

    private func row(_ record: DictationRecord) -> some View {
        HistoryRow(record: record)
            .contextMenu {
                if record.isRewrite {
                    if let answer = record.answer {
                        Button("Copy rewritten text") { copy(answer) }
                    }
                    Button("Copy original") { copy(record.text) }
                } else {
                    Button(record.isAssistant ? "Copy question" : "Copy") { copy(record.text) }
                    if let answer = record.answer {
                        Button("Copy answer") { copy(answer) }
                    }
                }
                Divider()
                Button("Delete", role: .destructive) { delete(record) }
            }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func delete(_ record: DictationRecord) {
        context.delete(record)
        try? context.save()
    }

    private func clearAll() {
        try? context.delete(model: DictationRecord.self)
        try? context.save()
    }

    private func export(csv: Bool) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = csv ? "Duck Keyboard history.csv" : "Duck Keyboard history.txt"
        panel.allowedContentTypes = [csv ? .commaSeparatedText : .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let body = csv ? HistoryExporter.csv(records) : HistoryExporter.plainText(records)
        try? body.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// The three kinds of history entry, each with its own icon and colour.
enum HistoryKind {
    case dictation, assistant, rewrite

    init(_ record: DictationRecord) {
        if record.isAssistant {
            self = .assistant
        } else if record.isRewrite {
            self = .rewrite
        } else {
            self = .dictation
        }
    }

    var title: String {
        switch self {
        case .dictation: return "Dictation"
        case .assistant: return "AI question"
        case .rewrite: return "Writing"
        }
    }

    var symbol: String {
        switch self {
        case .dictation: return "waveform"
        case .assistant: return "sparkles"
        case .rewrite: return "wand.and.stars"
        }
    }

    var tint: Color {
        switch self {
        case .dictation: return Duck.dictation
        case .assistant: return Duck.assistant
        case .rewrite: return Duck.writing
        }
    }
}

/// One history entry. Every kind shares the same frame: a coloured icon, a header line
/// (kind · time · app), the content, and a details line; the copy button appears on hover.
struct HistoryRow: View {
    let record: DictationRecord
    @State private var copied = false
    @State private var hovering = false

    private var kind: HistoryKind { HistoryKind(record) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            KindIcon(kind: kind)

            VStack(alignment: .leading, spacing: 8) {
                header
                switch kind {
                case .dictation: dictationContent
                case .assistant: assistantContent
                case .rewrite: rewriteContent
                }
                details
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            copyButton
                .opacity(hovering || copied ? 1 : 0)
        }
        .duckCard(padding: 12, highlighted: hovering)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    // MARK: Parts

    /// "Dictation · 10:42 · Slack" / "Write as email · 10:42 · Mail".
    private var header: some View {
        HStack(spacing: 6) {
            Text(kind == .rewrite ? record.rewriteActionTitle : kind.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(kind.tint)
            Group {
                Text("·")
                Text(record.createdAt, format: .dateTime.hour().minute())
                if let app = record.appName, !app.isEmpty {
                    Text("·")
                    Text(app).lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var dictationContent: some View {
        Text(record.text)
            .textSelection(.enabled)
            .lineLimit(5)
    }

    private var assistantContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(record.text)
                .fontWeight(.medium)
                .textSelection(.enabled)
                .lineLimit(3)
            if let answer = record.answer, !answer.isEmpty {
                QuotedBlock(text: answer, tint: kind.tint, lines: 6)
            }
        }
    }

    private var rewriteContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabelledText(label: "Before", text: record.text, lines: 3, dimmed: true)
            if let answer = record.answer {
                Image(systemName: "arrow.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(kind.tint)
                    .padding(.leading, 2)
                QuotedBlock(text: answer, tint: kind.tint, lines: 6, label: "After")
            }
        }
    }

    /// Words and model, quietly at the bottom.
    private var details: some View {
        HStack(spacing: 6) {
            Text("\(record.wordCount) words")
            Text("·")
            Text(record.displayModelName).lineLimit(1)
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }

    private var copyButton: some View {
        Button {
            NSPasteboard.general.clearContents()
            // AI entries: the answer is usually what you want; rewrites: the rewritten text.
            NSPasteboard.general.setString(record.answer ?? record.text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1))
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .foregroundStyle(copied ? Color.green : Color.secondary)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.borderless)
        .help(kind == .rewrite ? "Copy the rewritten text" : kind == .assistant ? "Copy the answer" : "Copy")
    }
}

/// The coloured square at the start of each entry.
private struct KindIcon: View {
    let kind: HistoryKind

    var body: some View {
        Image(systemName: kind.symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(kind.tint)
            .frame(width: 30, height: 30)
            .background(kind.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .help(kind.title)
    }
}

/// An answer or rewritten text: tinted background with an accent bar on the left.
private struct QuotedBlock: View {
    let text: String
    let tint: Color
    let lines: Int
    var label: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(tint.opacity(0.7))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                if let label {
                    Text(label.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(tint)
                }
                Text(text)
                    .textSelection(.enabled)
                    .lineLimit(lines)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// "BEFORE" over the original text, a little dimmed.
private struct LabelledText: View {
    let label: String
    let text: String
    let lines: Int
    var dimmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            Text(text)
                .textSelection(.enabled)
                .lineLimit(lines)
                .foregroundStyle(dimmed ? Color.secondary : Color.primary)
        }
        .padding(.leading, 13)   // lines up with the text inside QuotedBlock
    }
}

struct StatsHeader: View {
    let records: [DictationRecord]

    private var today: [DictationRecord] {
        records.filter { Calendar.current.isDateInToday($0.createdAt) }
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
            DuckStatTile(value: "\(today.count)", title: "Today", symbol: "sun.max.fill")
            DuckStatTile(value: "\(today.reduce(0) { $0 + $1.wordCount })", title: "Words today", symbol: "text.word.spacing")
            DuckStatTile(value: "\(records.filter(\.isDictation).count)", title: "Dictations",
                     symbol: HistoryKind.dictation.symbol, tint: HistoryKind.dictation.tint)
            DuckStatTile(value: "\(records.filter(\.isAssistant).count)", title: "AI questions",
                     symbol: HistoryKind.assistant.symbol, tint: HistoryKind.assistant.tint)
            DuckStatTile(value: "\(records.filter(\.isRewrite).count)", title: "Rewrites",
                     symbol: HistoryKind.rewrite.symbol, tint: HistoryKind.rewrite.tint)
            DuckStatTile(value: "\(records.reduce(0) { $0 + $1.wordCount })", title: "Total words",
                     symbol: "character.cursor.ibeam", tint: .secondary)
        }
    }
}

/// First run: show the three ways to fill History, with the user's actual keys.
private struct HistoryEmptyState: View {
    @Environment(Preferences.self) private var preferences

    var body: some View {
        DuckEmptyState(symbol: "waveform", title: "Your words will show up here",
                       message: "Everything you dictate, ask or rewrite is kept on this Mac.") {
            VStack(alignment: .leading, spacing: 10) {
                hint(HistoryKind.dictation) {
                    Text("Hold"); DuckKeycap(preferences.hotkey.keycapLabel, size: .regular); Text("in any text field and speak")
                }
                if preferences.assistantEnabled, preferences.assistantHotkey != .off {
                    hint(HistoryKind.assistant) {
                        Text("Hold"); DuckKeycap(preferences.assistantHotkey.keycapLabel, size: .regular); Text("and ask a question")
                    }
                }
                hint(HistoryKind.rewrite) {
                    Text("Press"); DuckKeycap("⌘G", size: .regular); Text("in a text field to fix the grammar")
                }
            }
            .font(.callout)
            .duckCard()
        }
    }

    private func hint<Content: View>(_ kind: HistoryKind, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) {
            IconTile(symbol: kind.symbol, tint: kind.tint, size: 24)
            content()
        }
    }
}
