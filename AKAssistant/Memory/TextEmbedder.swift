import Foundation
import Accelerate

/// What a piece of text is used for. EmbeddingGemma expects a different prefix for each, and
/// mixing them up noticeably hurts search quality.
enum EmbeddingRole {
    /// What the user is searching for.
    case query
    /// Something that can be found (a transcript paragraph, a dictation, a note).
    case document(title: String?)
    /// Symmetric matching: a spoken command against command examples, a meeting against tags.
    case classify

    func format(_ text: String) -> String {
        switch self {
        case .query:
            return "task: search result | query: \(text)"
        case .document(let title):
            let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let shown = trimmed.isEmpty ? "none" : trimmed
            return "title: \(shown) | text: \(text)"
        case .classify:
            return "task: classification | query: \(text)"
        }
    }
}

/// Turns text into unit-length vectors. Features only use this protocol, so the model behind it
/// (EmbeddingGemma 300M today, EmbeddingGemma 2 later) can change without touching them.
protocol TextEmbedder: AnyObject {
    /// Identifies model + size; stored with every vector so a model change triggers re-indexing.
    var modelID: String { get }
    var dimensions: Int { get }
    func embed(_ texts: [String], role: EmbeddingRole) async throws -> [[Float]]
}

enum EmbeddingError: LocalizedError {
    case notReady
    case noOutput

    var errorDescription: String? {
        switch self {
        case .notReady: return "The search model isn't loaded"
        case .noOutput: return "The search model returned nothing"
        }
    }
}

enum VectorMath {
    /// Matryoshka truncation: keep the first `dimensions` values, then re-normalise (required by
    /// EmbeddingGemma; truncated vectors aren't unit length any more).
    static func truncateAndNormalize(_ vector: [Float], to dimensions: Int) -> [Float] {
        normalize(Array(vector.prefix(dimensions)))
    }

    static func normalize(_ vector: [Float]) -> [Float] {
        var sumOfSquares: Float = 0
        vDSP_svesq(vector, 1, &sumOfSquares, vDSP_Length(vector.count))
        let length = sumOfSquares.squareRoot()
        guard length > 0 else { return vector }
        var scale = 1 / length
        var result = [Float](repeating: 0, count: vector.count)
        vDSP_vsmul(vector, 1, &scale, &result, 1, vDSP_Length(vector.count))
        return result
    }

    /// Cosine similarity of two unit vectors.
    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var result: Float = 0
        vDSP_dotpr(a, 1, b, 1, &result, vDSP_Length(a.count))
        return result
    }

    /// Normalised average (e.g. one vector for a whole meeting).
    static func mean(_ vectors: [[Float]]) -> [Float]? {
        guard let first = vectors.first else { return nil }
        var sum = [Float](repeating: 0, count: first.count)
        for v in vectors where v.count == sum.count {
            let current = sum
            vDSP_vadd(current, 1, v, 1, &sum, 1, vDSP_Length(sum.count))
        }
        return normalize(sum)
    }

    static func data(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func vector(_ data: Data) -> [Float] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}

/// FNV-1a 64-bit: a hash that stays the same across launches (Swift's `hashValue` doesn't),
/// used to notice when an indexed source has changed.
enum StableHash {
    static func of(_ parts: [String]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for part in parts {
            for byte in part.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01b3
            }
            hash ^= 0x1f   // separator so ["ab","c"] ≠ ["a","bc"]
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    /// Same, over raw bytes (e.g. a meeting's JSON-encoded transcript) plus strings.
    static func of(data: [Data], strings: [String]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for chunk in data {
            for byte in chunk {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01b3
            }
            hash ^= 0x1e
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return of([String(hash, radix: 16)] + strings)
    }
}
