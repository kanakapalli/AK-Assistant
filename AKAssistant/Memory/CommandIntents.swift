import Foundation
import os

/// One kind of Mac command, with example phrasings in several languages. Each resolves to a
/// canonical English phrase that `CommandParser` already understands, so a match always becomes a
/// command that's known to work.
struct CommandIntent {
    enum Slot {
        /// No details needed: the canonical phrase is the command.
        case none
        /// An app name: whatever's left after removing `drop` words, resolved with AppFinder.
        case app
        /// A number (digits, or English/Hindi number words): fills {n}.
        case number
        /// A number and a unit (seconds/minutes/hours): fills {n} {unit}; minutes by default.
        case duration(defaultValue: Int?, defaultUnit: String)
        /// Free text after removing `drop` words: fills {q}.
        case query
    }

    let id: String
    /// e.g. "Mute", "Open {app}", "Set volume to {n}", "Set a timer for {n} {unit}".
    let template: String
    let slot: Slot
    let examples: [String]
    /// Words that aren't part of the slot (verbs, fillers) in any of the example languages.
    var drop: [String] = []
}

/// Matches what was said to the closest command by meaning (EmbeddingGemma, multilingual),
/// for phrasings `CommandParser`'s patterns don't cover: "xcode kholo", "awaaz kam karo",
/// "das minute ka timer lagao", "make it louder".
@MainActor
final class CommandIntentMatcher {
    enum Result {
        /// Confident: run this canonical phrase.
        case run(phrase: String, score: Float)
        /// Close but not sure: offer these phrases as "Did you mean…".
        case suggest([String])
        /// Not a command (or the model isn't ready): let the AI handle it.
        case none
    }

    /// Starting thresholds; tune with the eval set (docs/EMBEDDINGS_PLAN.md §10).
    static let runThreshold: Float = 0.80
    static let suggestThreshold: Float = 0.65

    private let embedding: EmbeddingService
    private var exampleVectors: [[Float]] = []
    private var exampleIntent: [Int] = []          // example index → intent index
    private let log = Logger(subsystem: "com.natfirst.akassistant", category: "Memory")

    init(embedding: EmbeddingService) {
        self.embedding = embedding
    }

    /// Examples are embedded and the model is downloaded. (If it was unloaded, `match` starts
    /// loading it and lets the AI handle this one phrase.)
    var isReady: Bool { !exampleVectors.isEmpty && embedding.isDownloaded }

    /// Embeds every example once (cached on disk per model and catalogue version).
    func prepare() async {
        let examples = Self.intents.enumerated().flatMap { index, intent in intent.examples.map { (index, $0) } }
        let texts = examples.map { $0.1 }
        let catalogue = StableHash.of(texts + Self.intents.map(\.template))
        let cacheURL = MeetingStorage.folder.deletingLastPathComponent().appendingPathComponent("command-intents.json")

        if let data = try? Data(contentsOf: cacheURL),
           let cache = try? JSONDecoder().decode(Cache.self, from: data),
           cache.modelID == embedding.modelID, cache.catalogue == catalogue, cache.vectors.count == texts.count {
            exampleVectors = cache.vectors
            exampleIntent = examples.map { $0.0 }
            _ = try? await embedding.prepare()   // matching needs the model for what you say
            return
        }
        do {
            let started = Date()
            let vectors = try await embedding.embed(texts, role: .classify)
            exampleVectors = vectors
            exampleIntent = examples.map { $0.0 }
            let cache = Cache(modelID: embedding.modelID, catalogue: catalogue, vectors: vectors)
            if let data = try? JSONEncoder().encode(cache) { try? data.write(to: cacheURL) }
            log.info("Embedded \(texts.count) command examples in \(Date().timeIntervalSince(started), format: .fixed(precision: 1))s")
        } catch {
            log.error("Command examples couldn't be embedded: \(error.localizedDescription, privacy: .public)")
        }
    }

    func unload() {
        exampleVectors = []
        exampleIntent = []
    }

    /// Finds the command closest in meaning. Never waits for the model to load.
    func match(_ spoken: String) async -> Result {
        guard !exampleVectors.isEmpty,
              let vector = await embedding.embedIfLoaded([spoken], role: .classify)?.first else { return .none }

        // Best score per intent.
        var best: [Int: Float] = [:]
        for (i, example) in exampleVectors.enumerated() {
            let score = VectorMath.dot(vector, example)
            let intent = exampleIntent[i]
            if score > best[intent, default: -1] { best[intent] = score }
        }
        let ranked = best.sorted { $0.value > $1.value }
        guard let top = ranked.first else { return .none }
        log.info("Command match: \(Self.intents[top.key].id, privacy: .public) \(top.value, format: .fixed(precision: 3))")

        if top.value >= Self.runThreshold, let phrase = Self.fill(Self.intents[top.key], from: spoken) {
            return .run(phrase: phrase, score: top.value)
        }
        let close = ranked.prefix(3).filter { $0.value >= Self.suggestThreshold }
        guard !close.isEmpty else { return .none }
        var phrases: [String] = []
        for candidate in close {
            let intent = Self.intents[candidate.key]
            guard let phrase = Self.fill(intent, from: spoken) ?? intent.examples.first,
                  !phrases.contains(phrase) else { continue }
            phrases.append(phrase)
        }
        return phrases.isEmpty ? .none : .suggest(phrases)
    }

    private struct Cache: Codable {
        let modelID: String
        let catalogue: String
        let vectors: [[Float]]
    }

    // MARK: - Slot filling

    /// The canonical phrase for this intent with its details filled from what was said, or nil if
    /// a required detail (an app, a number) couldn't be found.
    static func fill(_ intent: CommandIntent, from spoken: String) -> String? {
        switch intent.slot {
        case .none:
            return intent.template
        case .app:
            let rest = leftover(spoken, dropping: intent.drop)
            guard !rest.isEmpty, let app = AppFinder.shared.installed(rest), app.strength >= .good else { return nil }
            return intent.template.replacingOccurrences(of: "{app}", with: app.app.name)
        case .number:
            guard let n = number(in: spoken) else { return nil }
            return intent.template.replacingOccurrences(of: "{n}", with: String(n))
        case .duration(let defaultValue, let defaultUnit):
            guard let n = number(in: spoken) ?? defaultValue else { return nil }
            let unit = durationUnit(in: spoken) ?? defaultUnit
            return intent.template
                .replacingOccurrences(of: "{n}", with: String(n))
                .replacingOccurrences(of: "{unit}", with: n == 1 ? String(unit.dropLast()) : unit)
        case .query:
            let rest = leftover(spoken, dropping: intent.drop)
            guard !rest.isEmpty else { return nil }
            return intent.template.replacingOccurrences(of: "{q}", with: rest)
        }
    }

    private static let fillers: Set<String> = [
        "please", "pls", "plz", "the", "a", "an", "my", "me", "for", "to", "hey", "ok", "okay", "can", "you",
        "could", "would", "will", "app", "application", "karo", "kar", "kardo", "karde", "dena", "do", "de",
        "kijiye", "kijie", "zara", "jara", "thoda", "na", "ko", "ka", "ki", "ke", "mera", "meri", "mere",
        "chahiye", "abhi", "now", "jaldi",
    ]

    /// What's left of the sentence once command words and fillers are removed ("xcode kholo" → "xcode").
    static func leftover(_ spoken: String, dropping drop: [String]) -> String {
        let dropSet = Set(drop.map { $0.lowercased() }).union(fillers)
        let words = spoken.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-'")).inverted)
            .filter { !$0.isEmpty && !dropSet.contains($0) }
        return words.joined(separator: " ")
    }

    private static let numberWords: [String: Int] = [
        // English
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
        "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20, "thirty": 30,
        "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90, "hundred": 100,
        "half": 30,
        // Hindi (romanised)
        "ek": 1, "teen": 3, "char": 4, "chaar": 4, "paanch": 5, "panch": 5, "chhe": 6, "che": 6, "saat": 7,
        "aath": 8, "nau": 9, "das": 10, "dus": 10, "gyarah": 11, "barah": 12, "pandrah": 15, "bees": 20,
        "pachees": 25, "pachchis": 25, "tees": 30, "chalees": 40, "chalis": 40, "pachaas": 50, "pachas": 50,
        "saath": 60, "sattar": 70, "assi": 80, "nabbe": 90, "sau": 100,
        // Hindi (Devanagari)
        "एक": 1, "दो": 2, "तीन": 3, "चार": 4, "पांच": 5, "पाँच": 5, "छह": 6, "सात": 7, "आठ": 8, "नौ": 9,
        "दस": 10, "पंद्रह": 15, "बीस": 20, "पच्चीस": 25, "तीस": 30, "चालीस": 40, "पचास": 50, "साठ": 60, "सौ": 100,
    ]

    /// The first number said: digits, or number words ("twenty five" → 25, "das" → 10).
    static func number(in spoken: String) -> Int? {
        if let range = spoken.range(of: #"\d+"#, options: .regularExpression) {
            return Int(spoken[range])
        }
        let words = spoken.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
        var total = 0
        var found = false
        for word in words {
            if let value = numberWords[word] {
                total += value
                found = true
            } else if word == "do", !found {
                continue   // Hindi "do" is usually "give", not 2
            } else if found {
                break
            }
        }
        return found ? total : nil
    }

    static func durationUnit(in spoken: String) -> String? {
        let s = spoken.lowercased()
        if ["second", "sec", "sekand", "सेकंड"].contains(where: { s.contains($0) }) { return "seconds" }
        if ["hour", "ghanta", "ghante", "घंटा", "घंटे"].contains(where: { s.contains($0) }) { return "hours" }
        if ["minute", "min", "minat", "मिनट"].contains(where: { s.contains($0) }) { return "minutes" }
        return nil
    }
}
