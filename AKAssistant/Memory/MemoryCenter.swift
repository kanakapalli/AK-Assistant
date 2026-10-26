import Foundation
import SwiftData
import Observation
import os

/// A search result: one indexed piece of text and where it came from.
struct MemoryHit: Identifiable, Hashable {
    let id: UUID              // index entry
    let kind: IndexKind
    let sourceID: UUID
    let locator: String?
    let text: String
    let title: String?
    let date: Date
    let score: Float
}

/// Smart search & memory: owns the search model, the index and the indexer, and answers searches.
/// Off until turned on in Settings › Search & memory (it downloads ~330 MB the first time).
@MainActor
@Observable
final class MemoryCenter {
    let embedding: EmbeddingService
    private(set) var indexer: MemoryIndexer?
    let commands: CommandIntentMatcher

    @ObservationIgnored private let index: VectorIndex
    @ObservationIgnored private var indexContainer: ModelContainer?
    @ObservationIgnored private var preferences: Preferences?
    @ObservationIgnored private var started = false
    private let log = Logger(subsystem: "com.natfirst.akassistant", category: "Memory")

    /// Weight of exact word matches in the final score (names, numbers, IDs).
    private let keywordWeight: Float = 0.2

    init() {
        let service = EmbeddingService()
        embedding = service
        index = VectorIndex(dimensions: service.dimensions)
        commands = CommandIntentMatcher(embedding: service)
    }

    var isEnabled: Bool { preferences?.memoryEnabled ?? false }
    var entryCount: Int { indexer?.entryCount ?? 0 }
    /// Search by meaning is available (model downloaded and something indexed).
    var canSearch: Bool { isEnabled && embedding.isDownloaded && index.count > 0 }

    func attach(appContainer: ModelContainer, preferences: Preferences, shouldPause: @escaping () -> Bool) {
        self.preferences = preferences
        do {
            let container = try MemoryStorage.makeContainer()
            indexContainer = container
            let indexer = MemoryIndexer(embedding: embedding, index: index, appContainer: appContainer,
                                        indexContainer: container, preferences: preferences)
            indexer.shouldPause = shouldPause
            self.indexer = indexer
        } catch {
            // A broken index is never fatal: delete it; it's rebuilt next launch.
            log.error("Index store failed to open: \(error.localizedDescription, privacy: .public)")
            MemoryStorage.deleteStore()
        }
    }

    /// Called a little after launch: loads the index and catches up on anything new.
    func start() {
        guard isEnabled, !started, let indexer else { return }
        started = true
        // Matching commands needs the model on every AI-key press: keep it loaded as long as the
        // speech model. Search alone can let it go after 15 minutes.
        embedding.idleUnloadInterval = preferences?.commandMatching != .off ? 4 * 60 * 60 : 15 * 60
        indexer.loadIndex()
        indexer.watchForChanges()
        indexer.sync()
        if preferences?.commandMatching != .off {
            Task { await commands.prepare() }
        }
    }

    /// Settings › Turn on: downloads and loads the model, then indexes everything.
    func enable() async {
        do {
            try await embedding.prepare()
        } catch {
            return   // the state shows the error
        }
        start()
        await commands.prepare()
    }

    func disable() {
        embedding.unload()
        commands.unload()
        started = false
    }

    func rebuildIndex() {
        guard let indexer else { return }
        indexer.clearAll()
        indexer.sync()
    }

    /// Deletes the index and the downloaded model.
    func deleteAll() {
        indexer?.clearAll()
        embedding.deleteModel()
        commands.unload()
        started = false
    }

    // MARK: - Search

    enum Scope {
        case meetings, history, all

        func includes(_ kind: IndexKind) -> Bool {
            switch self {
            case .meetings: return kind.isMeeting
            case .history: return kind.isHistory
            case .all: return true
            }
        }
    }

    /// Hybrid search: meaning (cosine similarity) plus exact words, newest first among ties.
    func search(_ query: String, scope: Scope, dates: ClosedRange<Date>? = nil,
                sources: Set<UUID>? = nil, limit: Int = 30) async -> [MemoryHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSearch, !trimmed.isEmpty, let context = indexContainer?.mainContext else { return [] }
        guard let vector = try? await embedding.embed([trimmed], role: .query).first else { return [] }

        let candidates = index.search(vector, limit: max(limit * 6, 120)) { row in
            guard scope.includes(row.kind) else { return false }
            if let dates, !dates.contains(row.date) { return false }
            if let sources, !sources.contains(row.sourceID) { return false }
            return true
        }
        guard !candidates.isEmpty else { return [] }

        // Fetch their text for keyword scoring and display.
        let ids = candidates.map(\.row.entryID)
        let descriptor = FetchDescriptor<IndexEntry>(predicate: #Predicate { ids.contains($0.id) })
        let entries = (try? context.fetch(descriptor)) ?? []
        var byID: [UUID: IndexEntry] = [:]
        for entry in entries { byID[entry.id] = entry }

        let terms = Self.terms(trimmed)
        var hits: [MemoryHit] = []
        for candidate in candidates {
            guard let entry = byID[candidate.row.entryID] else { continue }
            let keyword = Self.keywordScore(terms: terms, phrase: trimmed, in: entry.text)
            let score = (1 - keywordWeight) * candidate.score + keywordWeight * keyword
            hits.append(MemoryHit(id: entry.id, kind: entry.kind, sourceID: entry.sourceID, locator: entry.locator,
                                  text: entry.text, title: entry.title, date: entry.sourceDate, score: score))
        }
        hits.sort { $0.score == $1.score ? $0.date > $1.date : $0.score > $1.score }
        return Array(hits.prefix(limit))
    }

    /// Lower-cased words of 3+ letters, accents folded.
    static func terms(_ text: String) -> Set<String> {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return Set(folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 3 || $0.allSatisfy(\.isNumber) })
    }

    /// Share of query words found in the text, plus a bonus for the exact phrase.
    static func keywordScore(terms: Set<String>, phrase: String, in text: String) -> Float {
        guard !terms.isEmpty else { return 0 }
        let words = Self.terms(text)
        let found = terms.filter { words.contains($0) }.count
        var score = Float(found) / Float(terms.count)
        if phrase.count > 6, text.range(of: phrase, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
            score = min(1, score + 0.5)
        }
        return score
    }
}
