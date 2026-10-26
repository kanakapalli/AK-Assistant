import Foundation

/// What the AI makes of a meeting.
struct MeetingNotes {
    var title: String?
    var summary = ""
    var keyPoints: [String] = []
    var decisions: [String] = []
    var actionItems: [ActionItem] = []
}

/// Turns a transcript into a summary, key points, decisions and to-dos with the local chat model.
/// Long meetings are summarised part by part first, then the parts' notes are combined, so even
/// an hour-long transcript fits a small model's context.
@MainActor
enum MeetingSummarizer {
    /// About 3,300 tokens per part: comfortable for 4B models and still quick.
    static let wordsPerPart = 2_500

    static let instructions = """
        You write clear, accurate meeting notes. The transcript comes from automatic speech recognition and \
        may contain recognition mistakes. When lines start with a speaker label ("You:", "Speaker 2:", or a \
        name), use it to say who said or agreed to what; "You" is the person who recorded the meeting. \
        Without labels, don't guess who spoke. Only use information from the transcript, never invent names, \
        dates or tasks. Write the notes in the same language as the transcript.
        """

    static func summarize(transcript: String, llm: LLMService, model: ChatModel, detail: NotesDetail = .standard,
                          progress: (String) -> Void = { _ in }) async throws -> MeetingNotes {
        let words = transcript.split(whereSeparator: \.isWhitespace)
        let source: String
        let sourceLabel: String
        if words.count <= wordsPerPart {
            source = transcript
            sourceLabel = "Transcript"
        } else {
            // Long meeting: notes for each part first.
            let parts = stride(from: 0, to: words.count, by: wordsPerPart).map {
                words[$0..<min($0 + wordsPerPart, words.count)].joined(separator: " ")
            }
            var partNotes: [String] = []
            for (index, part) in parts.enumerated() {
                try Task.checkCancellation()
                progress("Reading part \(index + 1) of \(parts.count)…")
                let prompt = """
                    This is part \(index + 1) of \(parts.count) of a meeting transcript. List what matters in it as short \
                    lines starting with "- ": topics discussed, facts and numbers, decisions, and tasks someone agreed \
                    to do (with who and when, if said). No introduction.

                    Transcript part:
                    \"\"\"
                    \(part)
                    \"\"\"
                    """
                let notes = try await llm.generate(prompt, instructions: instructions, model: model, maxTokens: 700)
                partNotes.append("Part \(index + 1):\n\(notes)")
            }
            source = partNotes.joined(separator: "\n\n")
            sourceLabel = "Notes from each part of the meeting, in order"
        }

        try Task.checkCancellation()
        progress("Writing summary and to-dos…")
        let prompt = """
            Write meeting notes from the material below. Use exactly this format and these headings:

            TITLE: <a short title for the meeting, at most 8 words>
            SUMMARY:
            <\(detail.summaryLength): what the meeting was about and what was concluded>
            KEY POINTS:
            - <important point (\(detail.keyPointsHint))>
            DECISIONS:
            - <decision that was made, or None>
            ACTION ITEMS:
            - <task> | <who will do it (use the speaker label or name), or Unassigned> | <due date, or No date>

            \(sourceLabel):
            \"\"\"
            \(source)
            \"\"\"
            """
        let raw = try await llm.generate(prompt, instructions: instructions, model: model, maxTokens: detail.maxTokens)
        return parse(raw)
    }

    // MARK: - Parsing

    private enum Section { case none, summary, keyPoints, decisions, actionItems }

    /// Reads the TITLE / SUMMARY / KEY POINTS / DECISIONS / ACTION ITEMS format, tolerating markdown
    /// (bold headings, numbered lists) that small models like to add.
    static func parse(_ raw: String) -> MeetingNotes {
        var notes = MeetingNotes()
        var section = Section.none
        var summaryLines: [String] = []

        for rawLine in raw.components(separatedBy: .newlines) {
            var line = rawLine.replacingOccurrences(of: #"[*#]+"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let upper = line.uppercased()

            if upper.hasPrefix("TITLE:") {
                let title = clean(String(line.dropFirst("TITLE:".count)))
                if !title.isEmpty { notes.title = title }
                section = .none
                continue
            }
            if let found = heading(upper, line) {
                section = found.0
                line = found.1
                if line.isEmpty { continue }
            }

            let isBullet = line.range(of: #"^([-•*]|\d+[.)])\s+"#, options: .regularExpression) != nil
            let item = clean(line.replacingOccurrences(of: #"^([-•*]|\d+[.)])\s+"#, with: "", options: .regularExpression))
            guard !item.isEmpty, !isNone(item) else { continue }

            switch section {
            case .summary, .none:
                summaryLines.append(isBullet ? "• " + item : item)
            case .keyPoints:
                notes.keyPoints.append(item)
            case .decisions:
                notes.decisions.append(item)
            case .actionItems:
                if let action = actionItem(item) { notes.actionItems.append(action) }
            }
        }
        notes.summary = summaryLines.joined(separator: "\n")
        // Nothing followed the format at all: keep the model's text as the summary.
        if notes.summary.isEmpty && notes.keyPoints.isEmpty && notes.decisions.isEmpty && notes.actionItems.isEmpty {
            notes.summary = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return notes
    }

    private static func heading(_ upper: String, _ line: String) -> (Section, String)? {
        let headings: [(String, Section)] = [
            ("SUMMARY", .summary), ("KEY POINTS", .keyPoints), ("DECISIONS", .decisions),
            ("ACTION ITEMS", .actionItems), ("TO-DOS", .actionItems), ("TODOS", .actionItems),
        ]
        for (name, section) in headings where upper.hasPrefix(name) {
            let rest = line.dropFirst(name.count).trimmingCharacters(in: CharacterSet(charactersIn: ": ").union(.whitespaces))
            // "Summary of the call" isn't a heading; "SUMMARY:" and "Summary" are.
            if upper == name || upper.hasPrefix(name + ":") { return (section, rest) }
        }
        return nil
    }

    private static func actionItem(_ text: String) -> ActionItem? {
        let parts = text.split(separator: "|").map { clean(String($0)) }
        guard let task = parts.first, !task.isEmpty else { return nil }
        var item = ActionItem(text: task)
        if parts.count > 1, !["unassigned", "none", "unknown", "n/a", ""].contains(parts[1].lowercased()) {
            item.owner = parts[1]
        }
        if parts.count > 2, !["no date", "none", "unknown", "n/a", ""].contains(parts[2].lowercased()) {
            item.due = parts[2]
        }
        return item
    }

    private static func isNone(_ text: String) -> Bool {
        ["none", "none.", "n/a", "no decisions", "no action items", "none mentioned"].contains(text.lowercased())
    }

    private static func clean(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"<>")))
    }
}
