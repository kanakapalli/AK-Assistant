import Foundation

/// Something the AI hotkey can do on the Mac instead of (or as well as) answering.
/// `CommandParser` turns what you said into one of these; `CommandRunner` carries it out.
enum MacCommand: Equatable {
    // Apps, websites, folders
    /// "open Xcode", "launch Safari", "open youtube", "open downloads". Resolved when run:
    /// System Settings pane → folder → app → website.
    /// `strict` is false for verbs that might start an ordinary question ("start…", "show…"):
    /// if nothing matches, the question goes to the AI instead of failing.
    case open(String, strict: Bool)
    case quitApp(String)
    case hideApp(String)
    case hideOtherApps
    case runShortcut(String)

    // Search and files
    case webSearch(SearchSite, String)
    case directions(String)
    case findFile(String)
    case openFile(String)

    // Text
    case typeText(String)
    case copyText(String)

    // Sound, screen, media
    case setVolume(Int)
    case volumeStep(up: Bool)
    case mute(Bool)
    case brightnessStep(up: Bool)
    case media(MediaAction)
    case darkMode(Bool?)          // nil = toggle
    case wifi(Bool)
    case screenshot(ScreenshotKind)

    // Windows (sent to the app you were using)
    case window(WindowAction)

    // Power
    case lockScreen
    case sleepDisplay
    case sleepMac
    case screenSaver
    case keepAwake(TimeInterval?)  // nil = until you say stop
    case stopKeepAwake
    case emptyTrash
    case restart
    case shutDown
    case logOut

    // Timers and reminders
    case startTimer(TimeInterval)
    case remind(at: Date, text: String)
    case cancelTimers
    case timerStatus

    // Quick info
    case info(InfoKind)
    case help

    enum MediaAction: Equatable { case playPause, next, previous }
    enum ScreenshotKind: Equatable { case fullScreen, selection, recording }
    enum WindowAction: Equatable { case minimize, closeWindow, closeTab, newTab, newWindow, fullScreen }
    enum InfoKind: Equatable { case time, date, battery, storage, memory, uptime, macOSVersion, ipAddress, clipboard, frontApp }

    /// Actions that lose work or interrupt you if misheard. With "Ask before risky actions" on
    /// (Settings › Mac commands) these wait for you to click Run.
    var isRisky: Bool {
        switch self {
        case .quitApp, .emptyTrash, .sleepMac, .lockScreen, .restart, .shutDown, .logOut, .wifi(false), .window(.closeWindow), .window(.closeTab):
            return true
        default:
            return false
        }
    }

    /// Short title for the popup and History.
    var title: String {
        switch self {
        case .open(let name, _): return "Open \(name.capitalizedFirst)"
        case .quitApp(let name): return "Quit \(name.capitalizedFirst)"
        case .hideApp(let name): return "Hide \(name.capitalizedFirst)"
        case .hideOtherApps: return "Hide other apps"
        case .runShortcut(let name): return "Run shortcut “\(name)”"
        case .webSearch(let site, let query): return "Search \(site.name) for “\(query)”"
        case .directions(let place): return "Directions to \(place)"
        case .findFile(let name): return "Find files named “\(name)”"
        case .openFile(let name): return "Open file “\(name)”"
        case .typeText: return "Type text"
        case .copyText: return "Copy to clipboard"
        case .setVolume(let v): return "Set volume to \(v)%"
        case .volumeStep(let up): return up ? "Volume up" : "Volume down"
        case .mute(let on): return on ? "Mute" : "Unmute"
        case .brightnessStep(let up): return up ? "Brightness up" : "Brightness down"
        case .media(let a):
            switch a {
            case .playPause: return "Play / pause"
            case .next: return "Next track"
            case .previous: return "Previous track"
            }
        case .darkMode(let on):
            if let on { return on ? "Dark mode on" : "Light mode on" }
            return "Toggle dark mode"
        case .wifi(let on): return on ? "Turn Wi-Fi on" : "Turn Wi-Fi off"
        case .screenshot(let kind):
            switch kind {
            case .fullScreen: return "Screenshot"
            case .selection: return "Screenshot of an area"
            case .recording: return "Screen recording"
            }
        case .window(let a):
            switch a {
            case .minimize: return "Minimize window"
            case .closeWindow: return "Close window"
            case .closeTab: return "Close tab"
            case .newTab: return "New tab"
            case .newWindow: return "New window"
            case .fullScreen: return "Full screen"
            }
        case .lockScreen: return "Lock screen"
        case .sleepDisplay: return "Turn off display"
        case .sleepMac: return "Sleep"
        case .screenSaver: return "Start screen saver"
        case .keepAwake: return "Keep Mac awake"
        case .stopKeepAwake: return "Allow sleep"
        case .emptyTrash: return "Empty Trash"
        case .restart: return "Restart"
        case .shutDown: return "Shut down"
        case .logOut: return "Log out"
        case .startTimer(let seconds): return "Timer for \(DurationText.spoken(seconds))"
        case .remind(_, let text): return "Reminder: \(text)"
        case .cancelTimers: return "Cancel timers"
        case .timerStatus: return "Timers"
        case .info: return "Mac info"
        case .help: return "What I can do"
        }
    }

    var symbol: String {
        switch self {
        case .open: return "arrow.up.forward.app"
        case .quitApp: return "xmark.app"
        case .hideApp, .hideOtherApps: return "eye.slash"
        case .runShortcut: return "square.stack.3d.up"
        case .webSearch: return "magnifyingglass"
        case .directions: return "map"
        case .findFile, .openFile: return "doc.text.magnifyingglass"
        case .typeText: return "keyboard"
        case .copyText: return "doc.on.clipboard"
        case .setVolume, .volumeStep: return "speaker.wave.2"
        case .mute(let on): return on ? "speaker.slash" : "speaker.wave.2"
        case .brightnessStep: return "sun.max"
        case .media: return "playpause"
        case .darkMode: return "circle.lefthalf.filled"
        case .wifi: return "wifi"
        case .screenshot: return "camera.viewfinder"
        case .window: return "macwindow"
        case .lockScreen: return "lock"
        case .sleepDisplay: return "display"
        case .sleepMac: return "moon.zzz"
        case .screenSaver: return "sparkles.tv"
        case .keepAwake, .stopKeepAwake: return "cup.and.saucer"
        case .emptyTrash: return "trash"
        case .restart: return "arrow.clockwise"
        case .shutDown: return "power"
        case .logOut: return "rectangle.portrait.and.arrow.right"
        case .startTimer, .timerStatus, .cancelTimers: return "timer"
        case .remind: return "bell"
        case .info: return "info.circle"
        case .help: return "questionmark.circle"
        }
    }
}

/// Websites the AI hotkey can search.
enum SearchSite: String, CaseIterable, Equatable {
    case google, youtube, images, wikipedia, amazon, github, reddit, stackOverflow, maps, news

    var name: String {
        switch self {
        case .google: return "Google"
        case .youtube: return "YouTube"
        case .images: return "Google Images"
        case .wikipedia: return "Wikipedia"
        case .amazon: return "Amazon"
        case .github: return "GitHub"
        case .reddit: return "Reddit"
        case .stackOverflow: return "Stack Overflow"
        case .maps: return "Maps"
        case .news: return "Google News"
        }
    }

    /// Words that pick this site in "search <site> for …" / "… on <site>".
    var spokenNames: [String] {
        switch self {
        case .google: return ["google", "the web", "web", "online", "the internet", "internet"]
        case .youtube: return ["youtube", "you tube"]
        case .images: return ["images", "google images", "pictures", "photos"]
        case .wikipedia: return ["wikipedia", "wiki"]
        case .amazon: return ["amazon"]
        case .github: return ["github", "git hub"]
        case .reddit: return ["reddit"]
        case .stackOverflow: return ["stack overflow", "stackoverflow"]
        case .maps: return ["maps", "apple maps", "the map", "map"]
        case .news: return ["news", "google news"]
        }
    }

    func url(for query: String) -> URL? {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? query
        let string: String
        switch self {
        case .google: string = "https://www.google.com/search?q=\(q)"
        case .youtube: string = "https://www.youtube.com/results?search_query=\(q)"
        case .images: string = "https://www.google.com/search?tbm=isch&q=\(q)"
        case .wikipedia: string = "https://en.wikipedia.org/w/index.php?search=\(q)"
        case .amazon: string = "https://www.amazon.com/s?k=\(q)"
        case .github: string = "https://github.com/search?q=\(q)"
        case .reddit: string = "https://www.reddit.com/search/?q=\(q)"
        case .stackOverflow: string = "https://stackoverflow.com/search?q=\(q)"
        case .maps: string = "maps://?q=\(q)"
        case .news: string = "https://news.google.com/search?q=\(q)"
        }
        return URL(string: string)
    }
}

extension CharacterSet {
    /// Safe inside a query value: letters, digits and - . _ ~ (everything else is %-encoded).
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()
}

extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}

/// "10 minutes", "1 hour 30 minutes", "45 seconds".
enum DurationText {
    static func spoken(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        var parts: [String] = []
        if h > 0 { parts.append("\(h) hour" + (h == 1 ? "" : "s")) }
        if m > 0 { parts.append("\(m) minute" + (m == 1 ? "" : "s")) }
        if s > 0 || parts.isEmpty { parts.append("\(s) second" + (s == 1 ? "" : "s")) }
        return parts.joined(separator: " ")
    }

    /// "4:59" or "1:04:59", for countdowns.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
