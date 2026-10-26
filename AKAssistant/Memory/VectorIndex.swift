import Foundation
import Accelerate

/// All indexed vectors in one contiguous matrix, searched by brute force. 50,000 entries × 256
/// floats is ~51 MB and ranks in a few milliseconds, so no vector database is needed.
@MainActor
final class VectorIndex {
    struct Row {
        let entryID: UUID
        let kind: IndexKind
        let sourceID: UUID
        let locator: String?
        let date: Date
    }

    struct Hit {
        let row: Row
        let score: Float
    }

    private(set) var dimensions: Int
    private var rows: [Row] = []
    private var matrix: [Float] = []
    private var positions: [UUID: Int] = [:]   // entry id → row number

    var count: Int { rows.count }

    init(dimensions: Int) {
        self.dimensions = dimensions
    }

    func removeAll(dimensions: Int? = nil) {
        if let dimensions { self.dimensions = dimensions }
        rows.removeAll()
        matrix.removeAll()
        positions.removeAll()
    }

    func add(_ row: Row, vector: [Float]) {
        guard vector.count == dimensions else { return }
        if positions[row.entryID] != nil { remove(entryIDs: [row.entryID]) }
        positions[row.entryID] = rows.count
        rows.append(row)
        matrix.append(contentsOf: vector)
    }

    /// Removes rows (compacts the matrix; fine at this scale).
    func remove(entryIDs: Set<UUID>) {
        guard !entryIDs.isEmpty else { return }
        var newRows: [Row] = []
        var newMatrix: [Float] = []
        newRows.reserveCapacity(rows.count)
        newMatrix.reserveCapacity(matrix.count)
        for (i, row) in rows.enumerated() where !entryIDs.contains(row.entryID) {
            newRows.append(row)
            newMatrix.append(contentsOf: matrix[(i * dimensions)..<((i + 1) * dimensions)])
        }
        rows = newRows
        matrix = newMatrix
        positions = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($1.entryID, $0) })
    }

    func vector(for entryID: UUID) -> [Float]? {
        guard let i = positions[entryID] else { return nil }
        return Array(matrix[(i * dimensions)..<((i + 1) * dimensions)])
    }

    func rows(where include: (Row) -> Bool) -> [Row] {
        rows.filter(include)
    }

    /// Top `limit` rows by cosine similarity that pass `include`.
    func search(_ query: [Float], limit: Int, include: (Row) -> Bool = { _ in true }) -> [Hit] {
        guard query.count == dimensions, !rows.isEmpty else { return [] }
        // scores = matrix (rows × d) · query (d)
        var scores = [Float](repeating: 0, count: rows.count)
        matrix.withUnsafeBufferPointer { m in
            query.withUnsafeBufferPointer { q in
                vDSP_mmul(m.baseAddress!, 1, q.baseAddress!, 1, &scores, 1,
                          vDSP_Length(rows.count), 1, vDSP_Length(dimensions))
            }
        }
        var hits: [Hit] = []
        for (i, score) in scores.enumerated() where include(rows[i]) {
            hits.append(Hit(row: rows[i], score: score))
        }
        hits.sort { $0.score > $1.score }
        return Array(hits.prefix(limit))
    }
}
