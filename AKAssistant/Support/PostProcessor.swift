import Foundation

/// Light, rule-based cleanup of raw model output. An on-device LLM pass can replace this later.
enum PostProcessor {
    private static let artifactPattern = #"\[(?:BLANK_AUDIO|MUSIC|NOISE|SILENCE|INAUDIBLE)\]|\((?:music|silence|inaudible|noise)\)|<\|[^|]*\|>"#
    private static let fillerPattern = #"(?i)\b(?:um+|uh+|erm+|hmm+|uh-huh)\b[,.]?\s*"#

    static func clean(_ raw: String, removeFillers: Bool) -> String {
        var text = raw
        text = text.replacingOccurrences(of: artifactPattern, with: "", options: .regularExpression)
        if removeFillers {
            text = text.replacingOccurrences(of: fillerPattern, with: "", options: .regularExpression)
        }
        // Collapse whitespace and tidy spaces before punctuation.
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s+([,.!?;:])"#, with: "$1", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Capitalise the first letter.
        if let first = text.first, first.isLowercase {
            text = first.uppercased() + text.dropFirst()
        }
        return text
    }
}

/// Tidies the AI's reply for showing and for reading aloud.
enum AnswerCleaner {
    /// Removes any "thinking" section some models emit before the answer.
    static func forDisplay(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: #"(?s)<think>.*?</think>"#, with: "", options: .regularExpression)
        // Still thinking (no closing tag yet): hide it until the real answer starts.
        if let open = text.range(of: "<think>") {
            text = String(text[..<open.lowerBound])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Strips markdown symbols so the voice doesn't read out asterisks and hashes.
    static func forSpeech(_ text: String) -> String {
        var spoken = text
        spoken = spoken.replacingOccurrences(of: #"```[\s\S]*?```"#, with: " ", options: .regularExpression)
        spoken = spoken.replacingOccurrences(of: #"[*_`#>]+"#, with: "", options: .regularExpression)
        spoken = spoken.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        spoken = spoken.replacingOccurrences(of: #"(?m)^\s*[-•]\s+"#, with: "", options: .regularExpression)
        return spoken.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Cuts a growing AI answer into sentences, so the voice can start before the answer is finished.
struct SentenceSplitter {
    /// Characters of the answer already handed out.
    private(set) var consumed = 0
    /// Pieces shorter than this (like "1." in a list) wait and join the next sentence.
    var minimumLength = 8

    private static let enders: Set<Character> = [".", "!", "?", "…", "。", "！", "？"]

    /// Returns any complete sentences that have appeared since the last call.
    mutating func take(from text: String) -> [String] {
        guard text.count > consumed else { return [] }
        let pending = text.dropFirst(consumed)
        var pieces: [String] = []
        var pieceStart = pending.startIndex
        var i = pending.startIndex
        while i < pending.endIndex {
            let next = pending.index(after: i)
            let ch = pending[i]
            // A sentence ends at a newline, or at . ! ? followed by a space
            // (so "3.5" and "e.g.x" don't split, and the last word isn't cut off while it's still arriving).
            let isEnd = ch == "\n" || (Self.enders.contains(ch) && next < pending.endIndex && pending[next].isWhitespace)
            if isEnd {
                let piece = pending[pieceStart..<next]
                if piece.trimmingCharacters(in: .whitespacesAndNewlines).count >= minimumLength {
                    pieces.append(String(piece))
                    pieceStart = next
                }
            }
            i = next
        }
        consumed += pending.distance(from: pending.startIndex, to: pieceStart)
        return pieces
    }

    /// Whatever hasn't been handed out yet (call once the answer is complete).
    func remainder(of text: String) -> String {
        guard text.count > consumed else { return "" }
        return String(text.dropFirst(consumed))
    }
}
