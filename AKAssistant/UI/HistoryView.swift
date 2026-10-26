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
            StatsHeader(records: records)
            Picker("Show", selection: $kind) {
                ForEach(KindFilter.allCases) { filter in
                    Label(filter.rawValue, systemImage: filter.symbol).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 460)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            if filtered.isEmpty {
                ContentUnavailableView(
                    records.isEmpty ? "Nothing here yet" : "No matches",
                    systemImage: "waveform",
                    description: Text(records.isEmpty ? "Hold your hotkey in any text field and speak, hold the AI key and ask a question, or press a writing tool's shortcut (like ⌘G) in a text field." : "Try a different search or filter.")
                )
            } else {
                List {
                    ForEach(groupedByDay, id: \.day) { group in
                        Section {
                            ForEach(group.records) { record in
                                row(record)
                            }
                        } header: {
                            Text(dayTitle(group.day))
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                }
                .listStyle(.inset)
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
        panel.nameFieldStringValue = csv ? "AK Assistant history.csv" : "AK Assistant history.txt"
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
        case .dictation: return .blue
        case .assistant: return .purple
        case .rewrite: return .mint
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
                .opacity(hovering || copied ? 1 : 0.35)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
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
            .frame(width: 28, height: 28)
            .background(kind.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
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
        HStack(spacing: 32) {
            stat("Today", "\(today.count)")
            stat("Words today", "\(today.reduce(0) { $0 + $1.wordCount })")
            stat("Dictations", "\(records.filter(\.isDictation).count)", kind: .dictation)
            stat("AI questions", "\(records.filter(\.isAssistant).count)", kind: .assistant)
            stat("Rewrites", "\(records.filter(\.isRewrite).count)", kind: .rewrite)
            stat("Total words", "\(records.reduce(0) { $0 + $1.wordCount })")
            Spacer()
        }
        .padding(16)
    }

    private func stat(_ title: String, _ value: String, kind: HistoryKind? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
            HStack(spacing: 4) {
                if let kind {
                    Image(systemName: kind.symbol).foregroundStyle(kind.tint)
                }
                Text(title).foregroundStyle(.secondary)
            }
            .font(.caption)
        }
    }
}
