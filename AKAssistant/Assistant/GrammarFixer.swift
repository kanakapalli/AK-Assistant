import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Writing tools (see TextActions.swift): selects everything in the focused text field (⌘A), copies it (⌘C),
/// has the local AI model rewrite it, and pastes the result back over it.
/// The AppState side (status, clipboard, history) lives in `AppState.runTextAction(id:)`.
enum GrammarFixer {
    /// Longer text takes the local model too long and risks being cut off.
    static let maxCharacters = 8_000

    enum CopyResult {
        case text(String)
        /// The field was empty, nothing is focused, or the app didn't copy anything.
        case empty
        /// What got copied isn't text (e.g. files in Finder).
        case notText
        case noPermission
        /// A password field or "Secure Keyboard Entry" is blocking simulated keys.
        case secureInput
    }

    /// Sends ⌘A then ⌘C to the frontmost app and returns what it put on the clipboard.
    @MainActor
    static func copyAllFromFocusedField() async -> CopyResult {
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
            if !CGPreflightPostEventAccess() { _ = CGRequestPostEventAccess() }
            return .noPermission
        }
        if IsSecureEventInputEnabled() { return .secureInput }

        let pasteboard = NSPasteboard.general
        let before = pasteboard.changeCount
        TextInserter.sendCommandKey(kVK_ANSI_A)
        try? await Task.sleep(for: .milliseconds(90))
        TextInserter.sendCommandKey(kVK_ANSI_C)

        // Browsers, Electron and Office apps can take a moment to write the clipboard.
        for _ in 0..<60 where pasteboard.changeCount == before {
            try? await Task.sleep(for: .milliseconds(25))
        }
        // Unchanged clipboard: nothing was copied (an empty field copies nothing). Never "fix" the old clipboard.
        guard pasteboard.changeCount != before else { return .empty }
        if pasteboard.types?.contains(.fileURL) == true { return .notText }
        guard let text = pasteboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .empty }
        return .text(text)
    }

    /// ⌘A in the frontmost app.
    static func selectAll() {
        TextInserter.sendCommandKey(kVK_ANSI_A)
    }

    /// Enough room for the corrected text plus a little slack (a token is roughly 3–4 characters).
    /// Rewrites (e.g. as an email) can come out longer than the original, so they get more room.
    static func maxTokens(for text: String, rewriting: Bool) -> Int {
        min(4_096, max(rewriting ? 400 : 128, text.count / 2 + (rewriting ? 400 : 64)))
    }

    /// Removes things models add around the answer, and keeps the original's leading and trailing
    /// whitespace (e.g. a final newline) so only the mistakes change.
    static func clean(_ raw: String, original: String) -> String {
        var text = AnswerCleaner.forDisplay(raw)   // drops <think>…</think> and trims

        // A preface line: "Here is the corrected text:", "Corrected version:" …
        let lines = text.components(separatedBy: "\n")
        if lines.count > 1, let first = lines.first?.trimmingCharacters(in: .whitespaces).lowercased(),
           first.hasSuffix(":"), first.count < 60,
           ["here", "corrected", "fixed", "sure"].contains(where: { first.hasPrefix($0) }) {
            text = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let trimmedOriginal = original.trimmingCharacters(in: .whitespacesAndNewlines)
        // Wrapped in a code block the original didn't have.
        if text.hasPrefix("```"), text.hasSuffix("```"), !trimmedOriginal.hasPrefix("```") {
            var inner = text.components(separatedBy: "\n")
            if inner.count >= 3 {
                inner.removeFirst()
                inner.removeLast()
                text = inner.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        // Wrapped in quotes the original didn't have.
        for (open, close) in [("\"", "\""), ("“", "”"), ("'", "'")] {
            if text.count > 1, text.hasPrefix(open), text.hasSuffix(close),
               !(trimmedOriginal.hasPrefix(open) && trimmedOriginal.hasSuffix(close)) {
                text = String(text.dropFirst(open.count).dropLast(close.count))
            }
        }

        let leading = String(original.prefix { $0.isWhitespace })
        let trailing = String(String(original.reversed()).prefix { $0.isWhitespace }.reversed())
        return leading + text.trimmingCharacters(in: .whitespacesAndNewlines) + trailing
    }

    /// A correction is about as long as the original. Something much longer or shorter means the
    /// model answered or summarised the text instead of correcting it, so don't paste it.
    static func looksLikeCorrection(_ fixed: String, of original: String) -> Bool {
        let a = fixed.trimmingCharacters(in: .whitespacesAndNewlines).count
        let b = original.trimmingCharacters(in: .whitespacesAndNewlines).count
        guard a > 0 else { return false }
        return a <= b * 3 / 2 + 20 && a >= b / 2 - 10
    }
}
