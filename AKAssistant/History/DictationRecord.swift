import Foundation
import SwiftData

/// One saved dictation, one question to the AI assistant with its answer, or one writing-tool
/// rewrite (fix grammar, write as email, …) with the original text and the result.
/// (New properties have defaults, so SwiftData upgrades existing history automatically.)
@Model
final class DictationRecord {
    var id: UUID
    /// What you said: the dictated text, or your question to the AI.
    var text: String
    /// "dictation", "assistant" or "rewrite" ("grammar" for early grammar fixes).
    var kind: String = "dictation"
    /// The AI's reply for assistant entries; the rewritten text for rewrites.
    var answer: String?
    var createdAt: Date
    var duration: Double
    var modelName: String
    var appName: String?
    var appBundleID: String?

    init(text: String, duration: Double, modelName: String, appName: String?, appBundleID: String?,
         kind: String = "dictation", answer: String? = nil, createdAt: Date = .now) {
        self.id = UUID()
        self.text = text
        self.kind = kind
        self.answer = answer
        self.createdAt = createdAt
        self.duration = duration
        self.modelName = modelName
        self.appName = appName
        self.appBundleID = appBundleID
    }

    var isAssistant: Bool { kind == "assistant" }
    /// Made by a writing tool: `text` is the original, `answer` the rewritten text.
    var isRewrite: Bool { kind == "rewrite" || kind == "grammar" }
    var isDictation: Bool { !isAssistant && !isRewrite }

    /// Which writing tool made it ("Write as email"). Saved as the start of modelName: "Write as email · Qwen3 4B".
    var rewriteActionTitle: String {
        guard isRewrite else { return "" }
        if kind == "grammar" { return "Fix grammar" }
        return modelName.components(separatedBy: " · ").first ?? modelName
    }

    /// The model alone, without the writing tool's name in front.
    var displayModelName: String {
        guard isRewrite, kind != "grammar" else { return modelName }
        let parts = modelName.components(separatedBy: " · ")
        return parts.count > 1 ? parts.dropFirst().joined(separator: " · ") : modelName
    }

    var wordCount: Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }
}

enum HistoryPruner {
    /// Deletes entries older than the retention window. 0 = keep forever, -1 = keep nothing.
    @MainActor
    static func prune(context: ModelContext, retentionDays: Int) {
        guard retentionDays != 0 else { return }
        do {
            if retentionDays < 0 {
                try context.delete(model: DictationRecord.self)
            } else {
                let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: .now) ?? .distantPast
                try context.delete(model: DictationRecord.self, where: #Predicate { $0.createdAt < cutoff })
            }
            try context.save()
        } catch {
            NSLog("AK Assistant: history prune failed: \(error)")
        }
    }
}

enum HistoryExporter {
    static func csv(_ records: [DictationRecord]) -> String {
        let formatter = ISO8601DateFormatter()
        var lines = ["date,kind,app,model,seconds,text,answer"]
        for r in records {
            let text = r.text.replacingOccurrences(of: "\"", with: "\"\"")
            let app = (r.appName ?? "").replacingOccurrences(of: "\"", with: "\"\"")
            let answer = (r.answer ?? "").replacingOccurrences(of: "\"", with: "\"\"")
            lines.append("\(formatter.string(from: r.createdAt)),\(r.kind),\"\(app)\",\"\(r.modelName)\",\(String(format: "%.1f", r.duration)),\"\(text)\",\"\(answer)\"")
        }
        return lines.joined(separator: "\n")
    }

    static func plainText(_ records: [DictationRecord]) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return records.map { r in
            let stamp = "[\(formatter.string(from: r.createdAt))]"
            if r.isRewrite, let answer = r.answer {
                return "\(stamp) \(r.rewriteActionTitle)\nOriginal: \(r.text)\nRewritten: \(answer)"
            }
            if let answer = r.answer { return "\(stamp) Q: \(r.text)\nA: \(answer)" }
            return "\(stamp) \(r.text)"
        }.joined(separator: "\n\n")
    }
}
