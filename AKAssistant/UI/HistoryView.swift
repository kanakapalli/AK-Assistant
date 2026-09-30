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
        case all = "All", dictation = "Dictation", assistant = "AI"
        var id: String { rawValue }
    }

    private var filtered: [DictationRecord] {
        records.filter { record in
            switch kind {
            case .all: break
            case .dictation: if record.isAssistant { return false }
            case .assistant: if !record.isAssistant { return false }
            }
            guard !search.isEmpty else { return true }
            return record.text.localizedCaseInsensitiveContains(search)
                || (record.answer ?? "").localizedCaseInsensitiveContains(search)
                || (record.appName ?? "").localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            StatsHeader(records: records)
            Picker("Show", selection: $kind) {
                ForEach(KindFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 280)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            if filtered.isEmpty {
                ContentUnavailableView(
                    records.isEmpty ? "Nothing here yet" : "No matches",
                    systemImage: "waveform",
                    description: Text(records.isEmpty ? "Hold your hotkey in any text field and speak, or hold the AI key and ask a question." : "Try a different search or filter.")
                )
            } else {
                List(filtered) { record in
                    HistoryRow(record: record)
                        .contextMenu {
                            Button(record.isAssistant ? "Copy question" : "Copy") { copy(record.text) }
                            if let answer = record.answer {
                                Button("Copy answer") { copy(answer) }
                            }
                            Button("Delete", role: .destructive) { delete(record) }
                        }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("History")
        .searchable(text: $search, prompt: "Search dictations")
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
        .confirmationDialog("Delete all dictation history?", isPresented: $confirmClear) {
            Button("Delete All", role: .destructive) { clearAll() }
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

struct HistoryRow: View {
    let record: DictationRecord
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if record.isAssistant {
                Image(systemName: "sparkles")
                    .foregroundStyle(.purple)
                    .padding(.top, 2)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(record.text)
                    .textSelection(.enabled)
                    .lineLimit(4)
                    .fontWeight(record.isAssistant ? .medium : .regular)
                if let answer = record.answer {
                    Text(answer)
                        .textSelection(.enabled)
                        .lineLimit(6)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Text(record.createdAt, format: .dateTime.day().month().hour().minute())
                    if let app = record.appName { Text("· \(app)") }
                    Text("· \(record.wordCount) words")
                    Text("· \(record.modelName)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                // For AI entries, the answer is usually what you want to reuse.
                NSPasteboard.general.setString(record.answer ?? record.text, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy")
        }
        .padding(.vertical, 4)
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
            stat("Dictations", "\(records.filter { !$0.isAssistant }.count)")
            stat("AI questions", "\(records.filter(\.isAssistant).count)")
            stat("Total words", "\(records.reduce(0) { $0 + $1.wordCount })")
            Spacer()
        }
        .padding(16)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }
}
