import AppKit

/// Finds installed and running apps by a spoken name: "xcode", "x code", "chrome", "vs code", "settings".
@MainActor
final class AppFinder {
    static let shared = AppFinder()

    struct App {
        let name: String
        let url: URL
        let key: String         // "googlechrome"
        let words: [String]     // ["google", "chrome"]
    }

    enum Strength: Int, Comparable {
        case weak = 1, good = 2, exact = 3
        static func < (a: Strength, b: Strength) -> Bool { a.rawValue < b.rawValue }
    }

    private var apps: [App] = []
    private var indexedAt = Date.distantPast

    /// Common spoken names → bundle identifiers (also covers apps that live inside other apps, like Simulator).
    private static let aliases: [String: String] = [
        "chrome": "com.google.Chrome", "googlechrome": "com.google.Chrome",
        "vscode": "com.microsoft.VSCode", "visualstudio": "com.microsoft.VSCode", "visualstudiocode": "com.microsoft.VSCode", "code": "com.microsoft.VSCode",
        "settings": "com.apple.systempreferences", "systemsettings": "com.apple.systempreferences",
        "systempreferences": "com.apple.systempreferences", "preferences": "com.apple.systempreferences",
        "word": "com.microsoft.Word", "microsoftword": "com.microsoft.Word",
        "excel": "com.microsoft.Excel", "microsoftexcel": "com.microsoft.Excel",
        "powerpoint": "com.microsoft.Powerpoint", "outlook": "com.microsoft.Outlook",
        "teams": "com.microsoft.teams2", "microsoftteams": "com.microsoft.teams2",
        "finder": "com.apple.finder", "simulator": "com.apple.iphonesimulator", "iossimulator": "com.apple.iphonesimulator",
        "missioncontrol": "com.apple.exposelauncher", "launchpad": "com.apple.launchpad.launcher",
        "itunes": "com.apple.Music", "applemusic": "com.apple.Music", "imessage": "com.apple.MobileSMS",
        "messages": "com.apple.MobileSMS", "appletv": "com.apple.TV", "facetime": "com.apple.FaceTime",
        "appstore": "com.apple.AppStore", "quicktime": "com.apple.QuickTimePlayerX", "email": "com.apple.mail",
        "activitymonitor": "com.apple.ActivityMonitor", "taskmanager": "com.apple.ActivityMonitor",
        "terminal": "com.apple.Terminal", "iterm": "com.googlecode.iterm2", "textedit": "com.apple.TextEdit",
        "screenshot": "com.apple.screenshot.launcher", "calculator": "com.apple.calculator",
        "whatsapp": "net.whatsapp.WhatsApp", "slack": "com.tinyspeck.slackmacgap", "zoom": "us.zoom.xos",
        "spotify": "com.spotify.client", "firefox": "org.mozilla.firefox", "brave": "com.brave.Browser",
        "arc": "company.thebrowser.Browser", "edge": "com.microsoft.edgemac", "notion": "notion.id",
        "figma": "com.figma.Desktop", "postman": "com.postmanlabs.mac", "docker": "com.docker.docker",
        "androidstudio": "com.google.android.studio", "intellij": "com.jetbrains.intellij", "cursor": "com.todesktop.230313mzl4w4u92",
        "claude": "com.anthropic.claudefordesktop", "chatgpt": "com.openai.chat",
    ]

    /// Re-reads the Applications folders at most once a minute, so newly installed apps are found.
    private func refreshIfNeeded() {
        guard Date().timeIntervalSince(indexedAt) > 60 || apps.isEmpty else { return }
        indexedAt = Date()
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let folders = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                       "\(home)/Applications", "/System/Library/CoreServices/Applications"]
        var seen = Set<String>()
        var found: [App] = []
        func add(_ url: URL) {
            guard seen.insert(url.path).inserted else { return }
            let name = fm.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            found.append(App(name: name, url: url, key: Self.key(name), words: Self.words(name)))
        }
        for folder in folders {
            guard let items = try? fm.contentsOfDirectory(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            for item in items {
                if item.pathExtension == "app" {
                    add(item)
                } else if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                          let inner = try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                    // Vendor folders like "/Applications/Adobe Photoshop 2025/Adobe Photoshop 2025.app".
                    inner.filter { $0.pathExtension == "app" }.forEach(add)
                }
            }
        }
        add(URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"))
        apps = found
    }

    /// The installed app that best matches a spoken name.
    func installed(_ spoken: String) -> (app: App, strength: Strength)? {
        refreshIfNeeded()
        let q = Self.key(spoken)
        guard !q.isEmpty else { return nil }
        if let id = Self.aliases[q], let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            return (App(name: name, url: url, key: Self.key(name), words: Self.words(name)), .exact)
        }
        return Self.best(spoken, in: apps.map { ($0.name, $0) })
    }

    /// The running (Dock) app that best matches a spoken name.
    func running(_ spoken: String) -> NSRunningApplication? {
        let candidates = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap { app in app.localizedName.map { ($0, app) } }
        let q = Self.key(spoken)
        if let id = Self.aliases[q], let app = candidates.first(where: { $0.1.bundleIdentifier == id }) {
            return app.1
        }
        return Self.best(spoken, in: candidates).map { $0.app }
    }

    /// A few installed app names close to what was said, for "did you mean …".
    func suggestions(for spoken: String, limit: Int = 3) -> [String] {
        refreshIfNeeded()
        let q = Self.key(spoken)
        return apps
            .map { ($0.name, Self.distance(q, $0.key)) }
            .filter { $0.1 <= max(2, q.count / 2) }
            .sorted { $0.1 < $1.1 }
            .prefix(limit)
            .map { $0.0 }
    }

    // MARK: - Matching

    static func best<T>(_ spoken: String, in candidates: [(String, T)]) -> (app: T, strength: Strength)? {
        let q = key(spoken)
        let qWords = words(spoken)
        guard !q.isEmpty else { return nil }
        var best: (item: T, strength: Strength, score: Int, length: Int)?
        for (name, item) in candidates {
            let k = key(name)
            let w = words(name)
            var strength: Strength?
            var score = 0
            if k == q {
                strength = .exact; score = 100
            } else if !qWords.isEmpty, qWords.allSatisfy({ word in w.contains(word) }) {
                // "chrome" → "Google Chrome", "photoshop" → "Adobe Photoshop 2025"
                strength = .good; score = 80
            } else if q.count >= 3, k.hasPrefix(q) {
                strength = .good; score = 70
            } else if q.count >= 4, distance(q, k) <= max(1, q.count / 4) {
                // Small mishearings: "ex code" → "Xcode", "safary" → "Safari"
                strength = .good; score = 60 - distance(q, k)
            } else if q.count >= 4, k.contains(q) {
                strength = .weak; score = 40
            } else if q.count >= 5, let first = w.first, distance(q, first) <= 1 {
                strength = .weak; score = 30
            }
            guard let strength else { continue }
            if let current = best, (current.score, -current.length) >= (score, -k.count) { continue }
            best = (item, strength, score, k.count)
        }
        return best.map { ($0.item, $0.strength) }
    }

    /// "Google Chrome" → "googlechrome"; "X code" → "xcode".
    static func key(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    static func words(_ s: String) -> [String] {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased()
            .split(whereSeparator: { !($0.isLetter || $0.isNumber) })
            .map(String.init)
    }

    /// Levenshtein edit distance.
    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
