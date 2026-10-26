import Foundation
import SwiftData
import Observation
import os

/// Keeps the search index in step with meetings and history, in the background.
///
/// On launch and whenever the app's data is saved (debounced), it compares every source with what
/// was indexed (a stable fingerprint per source), then embeds new or changed sources and removes
/// deleted ones. It pauses while you dictate, ask the AI or record a meeting, so it never competes
/// with them for the GPU.
@MainActor
@Observable
final class MemoryIndexer {
    /// Sources still to (re)index.
    private(set) var pending = 0
    private(set) var isRunning = false
    private(set) var lastError: String?
    /// Passages in the index (for Settings).
    private(set) var entryCount = 0

    @ObservationIgnored private let embedding: EmbeddingService
    @ObservationIgnored private let index: VectorIndex
    @ObservationIgnored private let appContainer: ModelContainer
    @ObservationIgnored private let indexContainer: ModelContainer
    @ObservationIgnored private let preferences: Preferences
    /// True while something more important is using the models.
    @ObservationIgnored var shouldPause: () -> Bool = { false }
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var saveObserver: NSObjectProtocol?

    private let log = Logger(subsystem: "com.natfirst.akassistant", category: "Memory")
    private let batchSize = 8

    private var indexContext: ModelContext { indexContainer.mainContext }
    private var appContext: ModelContext { appContainer.mainContext }

    init(embedding: EmbeddingService, index: VectorIndex, appContainer: ModelContainer,
         indexContainer: ModelContainer, preferences: Preferences) {
        self.embedding = embedding
        self.index = index
        self.appContainer = appContainer
        self.indexContainer = indexContainer
        self.preferences = preferences
    }

    /// Re-checks a few seconds after the app's data is saved (meeting finished, dictation saved, edits).
    func watchForChanges() {
        guard saveObserver == nil else { return }
        saveObserver = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave, object: appContainer.mainContext, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleSync(after: 5) }
        }
    }

    func scheduleSync(after seconds: Double = 0) {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            if seconds > 0 { try? await Task.sleep(for: .seconds(seconds)) }
            guard !Task.isCancelled else { return }
            self?.sync()
        }
    }

    /// Loads the saved vectors into memory (once per launch / model).
    func loadIndex() {
        let modelID = embedding.modelID
        index.removeAll(dimensions: embedding.dimensions)
        let descriptor = FetchDescriptor<IndexEntry>(predicate: #Predicate { $0.modelID == modelID })
        let entries = (try? indexContext.fetch(descriptor)) ?? []
        for entry in entries {
            index.add(row(for: entry), vector: VectorMath.vector(entry.vector))
        }
        entryCount = index.count
        log.info("Loaded \(entries.count) search entries")
    }

    func sync() {
        guard preferences.memoryEnabled, runTask == nil else { return }
        runTask = Task { [weak self] in
            await self?.run()
            self?.runTask = nil
        }
    }

    /// Deletes every entry (e.g. before a rebuild or when memory is turned off).
    func clearAll() {
        runTask?.cancel()
        runTask = nil
        try? indexContext.delete(model: IndexEntry.self)
        try? indexContext.delete(model: IndexedSource.self)
        try? indexContext.save()
        index.removeAll()
        pending = 0
        entryCount = 0
    }

    // MARK: - Work

    private struct Job {
        let sourceID: UUID
        let group: String
        let fingerprint: String
    }

    private func run() async {
        isRunning = true
        defer { isRunning = false; pending = 0 }
        let modelID = embedding.modelID

        // What exists now.
        var wanted: [UUID: Job] = [:]
        var meetingsByID: [UUID: Meeting] = [:]
        var recordsByID: [UUID: DictationRecord] = [:]
        if preferences.memoryIndexMeetings {
            let meetings = (try? appContext.fetch(FetchDescriptor<Meeting>())) ?? []
            for meeting in meetings where meeting.state == .done {
                meetingsByID[meeting.id] = meeting
                wanted[meeting.id] = Job(sourceID: meeting.id, group: "meeting", fingerprint: Self.fingerprint(meeting))
            }
        }
        if preferences.memoryIndexHistory {
            let records = (try? appContext.fetch(FetchDescriptor<DictationRecord>())) ?? []
            for record in records {
                recordsByID[record.id] = record
                wanted[record.id] = Job(sourceID: record.id, group: "history",
                                        fingerprint: StableHash.of([record.text, record.answer ?? "", record.kind]))
            }
        }

        // What's indexed.
        let indexed = (try? indexContext.fetch(FetchDescriptor<IndexedSource>())) ?? []
        var indexedByID: [UUID: IndexedSource] = [:]
        for source in indexed { indexedByID[source.sourceID] = source }

        // Removed sources (or indexed with another model).
        for source in indexed where wanted[source.sourceID] == nil || source.modelID != modelID {
            removeEntries(for: source.sourceID)
            indexContext.delete(source)
        }
        try? indexContext.save()
        entryCount = index.count

        // New or changed sources, newest meetings first.
        let jobs = wanted.values.filter { job in
            guard let existing = indexedByID[job.sourceID], existing.modelID == modelID else { return true }
            return existing.fingerprint != job.fingerprint
        }
        pending = jobs.count
        guard !jobs.isEmpty else { return }
        log.info("Indexing \(jobs.count) changed sources")

        do {
            try await embedding.prepare()
        } catch {
            lastError = error.localizedDescription
            return
        }

        for job in jobs.sorted(by: { $0.group == "meeting" && $1.group != "meeting" }) {
            if Task.isCancelled { return }
            // Let dictation, the AI and meetings have the hardware.
            while shouldPause() {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { return }
            }
            do {
                try await index(job, meeting: meetingsByID[job.sourceID], record: recordsByID[job.sourceID], modelID: modelID)
                lastError = nil
            } catch {
                lastError = error.localizedDescription
                log.error("Indexing failed: \(error.localizedDescription, privacy: .public)")
            }
            pending = max(0, pending - 1)
            entryCount = index.count
        }
        try? indexContext.save()
    }

    /// One item to embed.
    private struct Item {
        let kind: IndexKind
        let locator: String?
        let text: String
    }

    private func index(_ job: Job, meeting: Meeting?, record: DictationRecord?, modelID: String) async throws {
        let id = job.sourceID
        var items: [Item] = []
        var title: String?
        var date = Date()

        // Skip anything deleted since this run started.
        if let meeting, meeting.modelContext != nil, !meeting.isDeleted {
            title = meeting.title
            date = meeting.startedAt
            items = Self.items(for: meeting)
        } else if let record, record.modelContext != nil, !record.isDeleted {
            date = record.createdAt
            if record.isAssistant, let answer = record.answer, !answer.isEmpty {
                items = [Item(kind: .answer, locator: nil, text: "Q: \(record.text)\nA: \(answer)")]
            } else if record.wordCount >= 4 {
                items = [Item(kind: .dictation, locator: nil, text: record.text)]
            }
            title = record.appName
        } else {
            return
        }

        // Embed in small batches, yielding between them.
        var vectors: [[Float]] = []
        var start = 0
        while start < items.count {
            let batch = items[start..<min(start + batchSize, items.count)].map(\.text)
            vectors += try await embedding.embed(batch, role: .document(title: title))
            start += batchSize
            while shouldPause() { try? await Task.sleep(for: .seconds(1)) }
        }

        removeEntries(for: id)
        for (item, vector) in zip(items, vectors) {
            let entry = IndexEntry(kind: item.kind, sourceID: id, locator: item.locator, text: item.text,
                                   title: title, sourceDate: date, vector: vector, modelID: modelID)
            indexContext.insert(entry)
            index.add(row(for: entry), vector: vector)
        }
        let existing = try indexContext.fetch(FetchDescriptor<IndexedSource>(predicate: #Predicate { $0.sourceID == id }))
        existing.forEach { indexContext.delete($0) }
        indexContext.insert(IndexedSource(sourceID: id, group: job.group, fingerprint: job.fingerprint, modelID: modelID))
        try indexContext.save()
    }

    private func removeEntries(for sourceID: UUID) {
        let descriptor = FetchDescriptor<IndexEntry>(predicate: #Predicate { $0.sourceID == sourceID })
        let entries = (try? indexContext.fetch(descriptor)) ?? []
        index.remove(entryIDs: Set(entries.map(\.id)))
        entries.forEach { indexContext.delete($0) }
    }

    private func row(for entry: IndexEntry) -> VectorIndex.Row {
        VectorIndex.Row(entryID: entry.id, kind: entry.kind, sourceID: entry.sourceID,
                        locator: entry.locator, date: entry.sourceDate)
    }

    // MARK: - What gets indexed

    static func fingerprint(_ meeting: Meeting) -> String {
        StableHash.of(data: [meeting.segmentsData, meeting.speakerNamesData, meeting.keyPointsData,
                             meeting.decisionsData, meeting.actionItemsData],
                      strings: [meeting.title, meeting.summary])
    }

    private static func items(for meeting: Meeting) -> [Item] {
        var items: [Item] = []
        for segment in meeting.segments {
            let who = meeting.speakerName(segment.speaker).map { "\($0): " } ?? ""
            items.append(Item(kind: .meetingParagraph, locator: segment.id.uuidString, text: who + segment.text))
        }
        if !meeting.summary.isEmpty {
            items.append(Item(kind: .meetingSummary, locator: nil, text: meeting.summary))
        }
        for point in meeting.keyPoints {
            items.append(Item(kind: .keyPoint, locator: nil, text: point))
        }
        for decision in meeting.decisions {
            items.append(Item(kind: .decision, locator: nil, text: "Decision: " + decision))
        }
        for item in meeting.actionItems {
            var text = "To-do: " + item.text
            if let owner = item.owner { text += " (owner: \(owner))" }
            if let due = item.due { text += " (due: \(due))" }
            items.append(Item(kind: .actionItem, locator: item.id.uuidString, text: text))
        }
        return items
    }
}
