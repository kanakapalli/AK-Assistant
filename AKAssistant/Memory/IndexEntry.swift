import Foundation
import SwiftData

/// What an indexed piece of text is.
enum IndexKind: String, CaseIterable {
    case meetingParagraph, meetingSummary, keyPoint, decision, actionItem
    case dictation, answer
    case note

    var isMeeting: Bool {
        switch self {
        case .meetingParagraph, .meetingSummary, .keyPoint, .decision, .actionItem: return true
        default: return false
        }
    }

    var isHistory: Bool { self == .dictation || self == .answer }
}

/// One embedded piece of text. Lives in its own store (Index.store): it can always be rebuilt
/// from meetings and history, so deleting it never loses anything.
@Model
final class IndexEntry {
    var id: UUID
    var kindRaw: String
    /// The Meeting / DictationRecord / note it came from.
    var sourceID: UUID
    /// Where inside the source: a transcript segment id, a to-do id…
    var locator: String?
    /// Exactly what was embedded (also used for keyword scoring and showing results).
    var text: String
    var title: String?
    var sourceDate: Date
    /// [Float] × dimensions.
    var vector: Data
    var modelID: String

    init(kind: IndexKind, sourceID: UUID, locator: String?, text: String, title: String?,
         sourceDate: Date, vector: [Float], modelID: String) {
        self.id = UUID()
        self.kindRaw = kind.rawValue
        self.sourceID = sourceID
        self.locator = locator
        self.text = text
        self.title = title
        self.sourceDate = sourceDate
        self.vector = VectorMath.data(vector)
        self.modelID = modelID
    }

    var kind: IndexKind { IndexKind(rawValue: kindRaw) ?? .dictation }
}

/// Which version of a source has been indexed (a stable hash of its text), so changed or deleted
/// sources are found on launch and re-indexed or removed.
@Model
final class IndexedSource {
    var sourceID: UUID
    var group: String         // "meeting" or "history"
    var fingerprint: String
    var modelID: String

    init(sourceID: UUID, group: String, fingerprint: String, modelID: String) {
        self.sourceID = sourceID
        self.group = group
        self.fingerprint = fingerprint
        self.modelID = modelID
    }
}

enum MemoryStorage {
    static var storeURL: URL {
        MeetingStorage.folder.deletingLastPathComponent().appendingPathComponent("Index.store")
    }

    static func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration("Index", schema: Schema([IndexEntry.self, IndexedSource.self]), url: storeURL)
        return try ModelContainer(for: IndexEntry.self, IndexedSource.self, configurations: config)
    }

    /// Deletes the index files (they're rebuilt from meetings and history).
    static func deleteStore() {
        let base = storeURL.path
        for suffix in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(atPath: base + suffix)
        }
    }
}
