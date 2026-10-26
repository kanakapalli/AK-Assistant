import Foundation
import SwiftData

/// One recorded meeting: its transcript, the AI's notes and the to-do list.
/// Lists are stored as JSON so SwiftData keeps the schema simple.
@Model
final class Meeting {
    var id: UUID
    var title: String
    var startedAt: Date
    /// Seconds recorded (set when the recording stops).
    var duration: Double = 0
    /// See `MeetingState`.
    var stateRaw: String = MeetingState.recording.rawValue
    var segmentsData: Data = Data()
    /// A few sentences on what the meeting was about.
    var summary: String = ""
    var keyPointsData: Data = Data()
    var decisionsData: Data = Data()
    var actionItemsData: Data = Data()
    /// File name inside `MeetingStorage.folder`, if the audio was kept.
    var audioFileName: String?
    /// Your microphone alone ("You"), for the clean-up pass. Same timeline as the mix.
    var micTrackFileName: String?
    /// The Mac's audio alone (the other people), for the clean-up pass.
    var macTrackFileName: String?
    /// Speaker id ("you", "s1"…) → the name shown. Edited in the Transcript tab.
    var speakerNamesData: Data = Data()
    /// The transcript was redone after the meeting (separate tracks, speakers).
    var transcriptCleaned: Bool = false
    /// Something worth knowing about this meeting (e.g. only the mic was recorded).
    var note: String?
    var speechModelName: String = ""
    var summaryModelName: String?
    /// The title is still the automatic "Meeting · date" one, so the AI may replace it.
    var hasDefaultTitle: Bool = true

    init(startedAt: Date = .now, speechModelName: String) {
        self.id = UUID()
        self.startedAt = startedAt
        self.title = "Meeting · " + startedAt.formatted(date: .abbreviated, time: .shortened)
        self.speechModelName = speechModelName
    }

    /// A new, unsaved Meeting with the same contents (used to move meetings between stores).
    func detachedCopy() -> Meeting {
        let copy = Meeting(startedAt: startedAt, speechModelName: speechModelName)
        copy.id = id
        copy.title = title
        copy.duration = duration
        copy.stateRaw = stateRaw
        copy.segmentsData = segmentsData
        copy.summary = summary
        copy.keyPointsData = keyPointsData
        copy.decisionsData = decisionsData
        copy.actionItemsData = actionItemsData
        copy.audioFileName = audioFileName
        copy.micTrackFileName = micTrackFileName
        copy.macTrackFileName = macTrackFileName
        copy.speakerNamesData = speakerNamesData
        copy.transcriptCleaned = transcriptCleaned
        copy.note = note
        copy.summaryModelName = summaryModelName
        copy.hasDefaultTitle = hasDefaultTitle
        return copy
    }

    var state: MeetingState {
        get { MeetingState(rawValue: stateRaw) ?? .done }
        set { stateRaw = newValue.rawValue }
    }

    var segments: [TranscriptSegment] {
        get { Self.decode(segmentsData) }
        set { segmentsData = Self.encode(newValue) }
    }

    var keyPoints: [String] {
        get { Self.decode(keyPointsData) }
        set { keyPointsData = Self.encode(newValue) }
    }

    var decisions: [String] {
        get { Self.decode(decisionsData) }
        set { decisionsData = Self.encode(newValue) }
    }

    var actionItems: [ActionItem] {
        get { Self.decode(actionItemsData) }
        set { actionItemsData = Self.encode(newValue) }
    }

    var speakerNames: [String: String] {
        get {
            guard !speakerNamesData.isEmpty else { return [:] }
            return (try? JSONDecoder().decode([String: String].self, from: speakerNamesData)) ?? [:]
        }
        set { speakerNamesData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    var audioURL: URL? { MeetingStorage.existingURL(audioFileName) }
    var micTrackURL: URL? { MeetingStorage.existingURL(micTrackFileName) }
    var macTrackURL: URL? { MeetingStorage.existingURL(macTrackFileName) }
    var hasTracks: Bool { micTrackURL != nil || macTrackURL != nil }

    /// "Priya" for "s2", if the transcript has speakers.
    func speakerName(_ id: String?) -> String? {
        guard let id else { return nil }
        return speakerNames[id] ?? MeetingSpeakers.defaultName(for: id)
    }

    /// Speakers in order of first appearance, with how long each talked.
    var speakerStats: [SpeakerStat] {
        var order: [String] = []
        var seconds: [String: Double] = [:]
        for segment in segments {
            guard let id = segment.speaker else { continue }
            if seconds[id] == nil { order.append(id) }
            seconds[id, default: 0] += segment.end - segment.start
        }
        return order.map { SpeakerStat(id: $0, seconds: seconds[$0] ?? 0) }
    }

    /// Renames a speaker everywhere: transcript labels, summary, key points, decisions and to-dos.
    func renameSpeaker(_ id: String, to newName: String) {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let old = speakerName(id), old != name else { return }
        var names = speakerNames
        names[id] = name
        speakerNames = names
        let swap = { (text: String) in MeetingSpeakers.replaceName(old, with: name, in: text) }
        summary = swap(summary)
        keyPoints = keyPoints.map(swap)
        decisions = decisions.map(swap)
        actionItems = actionItems.map { item in
            var item = item
            item.text = swap(item.text)
            item.owner = item.owner.map(swap)
            return item
        }
    }

    var hasSummary: Bool { !summary.isEmpty || !keyPoints.isEmpty || !actionItems.isEmpty }

    /// The transcript as plain text, one line per segment with its time.
    var plainTranscript: String {
        segments.map { segment in
            let who = speakerName(segment.speaker).map { "\($0): " } ?? ""
            return "[\(MeetingFormat.clock(segment.start))] \(who)\(segment.text)"
        }.joined(separator: "\n")
    }

    /// Transcript text without times (what the AI reads).
    var transcriptForAI: String {
        segments.map { segment in
            let who = speakerName(segment.speaker).map { "\($0): " } ?? ""
            return who + segment.text
        }.joined(separator: "\n")
    }

    var wordCount: Int {
        segments.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
    }

    /// Everything about the meeting as Markdown, for copying or exporting.
    var markdown: String {
        var lines = ["# \(title)", "",
                     "\(startedAt.formatted(date: .long, time: .shortened)) · \(MeetingFormat.duration(duration))", ""]
        if !summary.isEmpty { lines += ["## Summary", "", summary, ""] }
        if !keyPoints.isEmpty { lines += ["## Key points", ""] + keyPoints.map { "- \($0)" } + [""] }
        if !decisions.isEmpty { lines += ["## Decisions", ""] + decisions.map { "- \($0)" } + [""] }
        if !actionItems.isEmpty {
            lines += ["## Action items", ""] + actionItems.map { item in
                var line = "- [\(item.done ? "x" : " ")] \(item.text)"
                if let owner = item.owner { line += " — \(owner)" }
                if let due = item.due { line += " (due \(due))" }
                return line
            } + [""]
        }
        if !segments.isEmpty { lines += ["## Transcript", "", plainTranscript, ""] }
        return lines.joined(separator: "\n")
    }

    private static func decode<T: Decodable>(_ data: Data) -> [T] {
        guard !data.isEmpty else { return [] }
        return (try? JSONDecoder().decode([T].self, from: data)) ?? []
    }

    private static func encode<T: Encodable>(_ value: [T]) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }
}

enum MeetingState: String, Codable {
    case recording, transcribing, summarizing, done

    var title: String {
        switch self {
        case .recording: return "Recording"
        case .transcribing: return "Transcribing"
        case .summarizing: return "Writing notes"
        case .done: return "Done"
        }
    }
}

/// A stretch of the transcript (about 15–30 seconds).
struct TranscriptSegment: Codable, Identifiable, Hashable {
    var id = UUID()
    /// Seconds from the start of the meeting.
    var start: Double
    var end: Double
    var text: String
    /// "you", "others", "s1", "s2"… nil for the live transcript (no speakers yet).
    var speaker: String? = nil
}

/// How long one speaker talked in a meeting.
struct SpeakerStat: Identifiable, Hashable {
    let id: String
    let seconds: Double
}

/// A to-do that came out of the meeting (or was added by hand).
struct ActionItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var text: String
    var owner: String?
    var due: String?
    var done = false
}

/// Where meeting audio lives: ~/Library/Application Support/AK Assistant/Meetings.
enum MeetingStorage {
    /// Created once, the first time it's needed.
    static let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("AK Assistant/Meetings", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// The meetings database (~/Library/Application Support/AK Assistant/Meetings.store), private to
    /// AK Assistant so other apps' SwiftData stores can't touch it.
    static let storeURL: URL = {
        folder.deletingLastPathComponent().appendingPathComponent("Meetings.store")
    }()

    /// Total size of all meeting audio on disk.
    static func bytesUsed() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(Int64(0)) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    static func existingURL(_ fileName: String?) -> URL? {
        guard let fileName else { return nil }
        let url = folder.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Deletes the playback audio and both tracks.
    static func deleteAudio(of meeting: Meeting) {
        deleteTracks(of: meeting)
        if let url = meeting.audioURL { try? FileManager.default.removeItem(at: url) }
    }

    /// Deletes just the separate mic / Mac tracks (kept only for redoing the clean-up).
    static func deleteTracks(of meeting: Meeting) {
        for url in [meeting.micTrackURL, meeting.macTrackURL].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: url)
        }
        meeting.micTrackFileName = nil
        meeting.macTrackFileName = nil
    }
}

/// Speaker ids and their default names.
enum MeetingSpeakers {
    static let you = "you"
    static let others = "others"

    /// "s3" → "Speaker 3"
    static func id(forNumber number: Int) -> String { "s\(number)" }

    static func defaultName(for id: String) -> String {
        switch id {
        case you: return "You"
        case others: return "Others"
        default:
            if id.hasPrefix("s"), let number = Int(id.dropFirst()) { return "Speaker \(number)" }
            return id
        }
    }

    /// Whole-word, case-sensitive replace ("Speaker 1" doesn't touch "Speaker 10").
    static func replaceName(_ old: String, with new: String, in text: String) -> String {
        let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: old) + "(?![\\p{L}\\p{N}])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: new))
    }
}

enum MeetingFormat {
    /// 75 → "1:15", 3725 → "1:02:05"
    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// 3725 → "1 h 2 min", 45 → "45 s"
    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s) s" }
        let minutes = s / 60
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }
}
