import AppKit
import Carbon.HIToolbox
import os

/// What happened when a command ran.
enum CommandOutcome: Equatable {
    /// Quick action: a short note in the popup capsule ("Opened Xcode").
    case done(String)
    /// Information: shown in the answer card (and read aloud, depending on Settings).
    case answer(String)
    /// Couldn't do it; the message says why.
    case failed(String)
    /// Not a command after all ("start a business plan"): hand the question to the AI.
    case notHandled
}

/// What the command needs to know about where you were.
struct CommandContext {
    /// The app that was in front when you pressed the hotkey (window commands and typing go there).
    var targetApp: NSRunningApplication?
    var restoreClipboard = true
}

/// Carries out `MacCommand`s.
@MainActor
final class CommandRunner {
    let timers = TimerCenter()
    private var keepAwake: Process?
    private let log = Logger(subsystem: "com.natfirst.akassistant", category: "Commands")

    var isKeepingAwake: Bool { keepAwake?.isRunning == true }

    func run(_ command: MacCommand, context: CommandContext) async -> CommandOutcome {
        log.info("Running command: \(command.title, privacy: .public)")
        switch command {
        case .open(let target, let strict): return await openTarget(target, strict: strict)
        case .quitApp(let name): return quit(name, context: context)
        case .hideApp(let name): return hide(name, context: context)
        case .hideOtherApps:
            let keep = frontApp(context)
            var count = 0
            for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular
                && app != keep && app.bundleIdentifier != Bundle.main.bundleIdentifier && !app.isHidden {
                if app.hide() { count += 1 }
            }
            return .done(count == 0 ? "Nothing else to hide" : "Hid \(count) app\(count == 1 ? "" : "s")")
        case .runShortcut(let name): return await runShortcut(name)

        case .webSearch(let site, let query):
            guard let url = site.url(for: query) else { return .failed("Couldn't build that search.") }
            NSWorkspace.shared.open(url)
            return .done("Searching \(site.name)…")
        case .directions(let place):
            let q = place.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? place
            guard let url = URL(string: "maps://?daddr=\(q)") else { return .failed("Couldn't open Maps.") }
            NSWorkspace.shared.open(url)
            return .done("Directions to \(place.capitalizedFirst)")
        case .findFile(let name): return await findFiles(name, open: false)
        case .openFile(let name): return await findFiles(name, open: true)

        case .typeText(let text):
            await bringBack(context)
            let result = TextInserter.insert(text, restoreClipboard: context.restoreClipboard)
            return result.reachedApp ? .done("Typed it") : .failed("Couldn't type here, so the text is on your clipboard. Press ⌘V to paste it.")
        case .copyText(let text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            return .done("Copied to clipboard")

        case .setVolume(let level):
            let r = await Shell.appleScript("set volume without output muted\nset volume output volume \(level)")
            return r.ok ? .done("Volume \(level)%") : .failed("Couldn't change the volume.")
        case .volumeStep(let up):
            KeySender.press(up ? .soundUp : .soundDown, times: 2)
            return .done(up ? "Volume up" : "Volume down")
        case .mute(let on):
            let r = await Shell.appleScript(on ? "set volume with output muted" : "set volume without output muted")
            return r.ok ? .done(on ? "Muted" : "Sound on") : .failed("Couldn't change the sound.")
        case .brightnessStep(let up):
            KeySender.press(up ? .brightnessUp : .brightnessDown, times: 2)
            return .done(up ? "Brighter" : "Dimmer")
        case .media(let action):
            switch action {
            case .playPause: KeySender.press(.play); return .done("Play / pause")
            case .next: KeySender.press(.next); return .done("Next track")
            case .previous: KeySender.press(.previous); return .done("Previous track")
            }
        case .darkMode(let on):
            let value = on.map { $0 ? "true" : "false" } ?? "not dark mode"
            let r = await Shell.appleScript("tell application \"System Events\" to tell appearance preferences to set dark mode to \(value)")
            if r.ok {
                let isDark = await Shell.appleScript("tell application \"System Events\" to tell appearance preferences to get dark mode").output == "true"
                return .done(isDark ? "Dark mode on" : "Light mode on")
            }
            return automationFailure(r, app: "System Events")
        case .wifi(let on): return await wifi(on)
        case .screenshot(let kind):
            await KeySender.waitForModifiersReleased()
            try? await Task.sleep(for: .milliseconds(350))   // let the popup get out of the picture
            switch kind {
            case .fullScreen: KeySender.press(kVK_ANSI_3, [.maskCommand, .maskShift])
            case .selection: KeySender.press(kVK_ANSI_4, [.maskCommand, .maskShift])
            case .recording: KeySender.press(kVK_ANSI_5, [.maskCommand, .maskShift])
            }
            return .done(kind == .fullScreen ? "Screenshot saved" : "Drag to choose")

        case .window(let action): return await window(action, context: context)

        case .lockScreen:
            await KeySender.waitForModifiersReleased()
            KeySender.press(kVK_ANSI_Q, [.maskCommand, .maskControl])
            return .done("Locked")
        case .sleepDisplay:
            let r = await Shell.run("/usr/bin/pmset", ["displaysleepnow"])
            return r.ok ? .done("Display off") : .failed("Couldn't turn off the display.")
        case .sleepMac:
            let r = await Shell.run("/usr/bin/pmset", ["sleepnow"])
            return r.ok ? .done("Going to sleep") : .failed("Couldn't put the Mac to sleep.")
        case .screenSaver:
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app"))
            return .done("Screen saver")
        case .keepAwake(let seconds): return startKeepAwake(seconds)
        case .stopKeepAwake:
            guard let process = keepAwake, process.isRunning else { return .done("Your Mac can sleep normally") }
            process.terminate()
            keepAwake = nil
            return .done("Your Mac can sleep again")
        case .emptyTrash:
            let r = await Shell.appleScript("tell application \"Finder\" to empty trash")
            return r.ok ? .done("Trash emptied") : automationFailure(r, app: "Finder")
        case .restart, .shutDown, .logOut:
            // macOS shows its own "Are you sure?" dialog for these, with a countdown you can cancel.
            let event = command == .restart ? "rrst" : (command == .shutDown ? "rsdn" : "logo")
            let r = await Shell.appleScript("tell application \"loginwindow\" to «event aevt\(event)»")
            return r.ok ? .done(command.title + "…") : automationFailure(r, app: "loginwindow")

        case .startTimer(let seconds):
            timers.add(label: "Timer", fireDate: Date().addingTimeInterval(seconds), isReminder: false, length: seconds)
            return .done("Timer: \(DurationText.spoken(seconds))")
        case .remind(let date, let text):
            timers.add(label: text, fireDate: date, isReminder: true, length: nil)
            return .answer("Okay, I'll remind you \(Self.when(date)): \(text)")
        case .cancelTimers:
            let count = timers.cancelAll()
            return .done(count == 0 ? "No timers running" : "Cancelled \(count) timer\(count == 1 ? "" : "s")")
        case .timerStatus:
            return .answer(timers.statusText())

        case .info(let kind): return .answer(info(kind, context: context))
        case .help: return .answer(ToolCatalog.spokenSummary)
        }
    }

    // MARK: - Apps, sites, folders

    private func openTarget(_ target: String, strict: Bool) async -> CommandOutcome {
        let lower = target.lowercased()
        if let pane = SettingsPane.match(lower) {
            NSWorkspace.shared.open(pane.url)
            return .done("Opened \(pane.name) settings")
        }
        if let folder = Folder.match(lower) {
            NSWorkspace.shared.open(folder.url)
            return .done("Opened \(folder.name)")
        }
        let app = AppFinder.shared.installed(target)
        if let app, app.strength == .exact { return await launch(app.app) }
        if let site = Website.match(lower) {
            NSWorkspace.shared.open(site.url)
            return .done("Opened \(site.name)")
        }
        if let url = Website.domainURL(lower) {
            NSWorkspace.shared.open(url)
            return .done("Opened \(url.host ?? lower)")
        }
        if let app, app.strength >= .good || strict { return await launch(app.app) }
        guard strict else { return .notHandled }
        let close = AppFinder.shared.suggestions(for: target)
        var message = "I couldn't find an app or website called “\(target)”."
        if !close.isEmpty { message += " Did you mean \(close.joined(separator: " or "))?" }
        return .failed(message)
    }

    private func launch(_ app: AppFinder.App) async -> CommandOutcome {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            _ = try await NSWorkspace.shared.openApplication(at: app.url, configuration: configuration)
            return .done("Opened \(app.name)")
        } catch {
            return .failed("Couldn't open \(app.name): \(error.localizedDescription)")
        }
    }

    private func frontApp(_ context: CommandContext) -> NSRunningApplication? {
        let ours = Bundle.main.bundleIdentifier
        if let app = context.targetApp, app.bundleIdentifier != ours { return app }
        let front = NSWorkspace.shared.frontmostApplication
        return front?.bundleIdentifier == ours ? nil : front
    }

    private func isThis(_ name: String) -> Bool {
        ["this", "it", "this app", "current app", "the current app", "this window", "that"].contains(name.lowercased())
    }

    private func quit(_ name: String, context: CommandContext) -> CommandOutcome {
        let app = isThis(name) ? frontApp(context) : AppFinder.shared.running(name)
        guard let app else {
            if isThis(name) { return .failed("There's no app in front to quit.") }
            if let installed = AppFinder.shared.installed(name), installed.strength >= .good {
                return .done("\(installed.app.name) isn't running")
            }
            return .failed("No running app called “\(name)”.")
        }
        let title = app.localizedName ?? name
        return app.terminate() ? .done("Quit \(title)") : .failed("\(title) didn't quit. It may be showing a dialog.")
    }

    private func hide(_ name: String, context: CommandContext) -> CommandOutcome {
        let app = isThis(name) ? frontApp(context) : AppFinder.shared.running(name)
        guard let app else { return isThis(name) ? .failed("There's no app in front to hide.") : .notHandled }
        app.hide()
        return .done("Hid \(app.localizedName ?? name)")
    }

    /// Puts the app you were using back in front before pressing keys in it.
    private func bringBack(_ context: CommandContext) async {
        if let app = frontApp(context), app != NSWorkspace.shared.frontmostApplication {
            app.activate()
            try? await Task.sleep(for: .milliseconds(250))
        }
        await KeySender.waitForModifiersReleased()
    }

    private func window(_ action: MacCommand.WindowAction, context: CommandContext) async -> CommandOutcome {
        guard let app = frontApp(context) else { return .failed("There's no window in front.") }
        await bringBack(context)
        let browsers: Set<String> = ["com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox", "company.thebrowser.Browser",
                                     "com.microsoft.edgemac", "com.brave.Browser", "com.operasoftware.Opera"]
        let name = app.localizedName ?? "the app"
        switch action {
        case .minimize: KeySender.press(kVK_ANSI_M, .maskCommand)
        case .closeTab: KeySender.press(kVK_ANSI_W, .maskCommand)
        case .closeWindow:
            if browsers.contains(app.bundleIdentifier ?? "") {
                KeySender.press(kVK_ANSI_W, [.maskCommand, .maskShift])
            } else {
                KeySender.press(kVK_ANSI_W, .maskCommand)
            }
        case .newTab: KeySender.press(kVK_ANSI_T, .maskCommand)
        case .newWindow: KeySender.press(kVK_ANSI_N, .maskCommand)
        case .fullScreen: KeySender.press(kVK_ANSI_F, [.maskCommand, .maskControl])
        }
        return .done("\(MacCommand.window(action).title) · \(name)")
    }

    private func runShortcut(_ name: String) async -> CommandOutcome {
        let list = await Shell.run("/usr/bin/shortcuts", ["list"])
        let names = list.output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        guard let match = AppFinder.best(name, in: names.map { ($0, $0) }) else {
            return .failed("I couldn't find a shortcut called “\(name)” in the Shortcuts app.")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["run", match.app]
        do {
            try process.run()
            return .done("Running “\(match.app)”")
        } catch {
            return .failed("Couldn't run the shortcut: \(error.localizedDescription)")
        }
    }

    // MARK: - Files

    private func findFiles(_ name: String, open: Bool) async -> CommandOutcome {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let result = await Shell.run("/usr/bin/mdfind", ["-onlyin", home, "-name", name])
        let skip = ["/Library/", "/.Trash/", "/node_modules/", "/.git/", "/DerivedData/", ".app/"]
        let wanted = AppFinder.key(name)
        let urls = result.output.split(separator: "\n").prefix(400)
            .map { URL(fileURLWithPath: String($0)) }
            .filter { url in !skip.contains { url.path.contains($0) } }
            .sorted { a, b in
                let ae = AppFinder.key(a.deletingPathExtension().lastPathComponent) == wanted
                let be = AppFinder.key(b.deletingPathExtension().lastPathComponent) == wanted
                if ae != be { return ae }
                return Self.modified(a) > Self.modified(b)
            }
        guard let first = urls.first else { return .failed("I couldn't find any files named “\(name)”.") }
        if open {
            NSWorkspace.shared.open(first)
            return .done("Opened \(first.lastPathComponent)")
        }
        let top = Array(urls.prefix(8))
        NSWorkspace.shared.activateFileViewerSelecting(Array(top.prefix(5)))
        let lines = top.map { url in
            "• \(url.lastPathComponent) — \(url.deletingLastPathComponent().path.replacingOccurrences(of: home, with: "~"))"
        }
        let header = urls.count == 1 ? "Found 1 file. It's selected in Finder:" : "Found \(urls.count) files. The newest are selected in Finder:"
        return .answer(([header] + lines).joined(separator: "\n"))
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    // MARK: - System

    private func wifi(_ on: Bool) async -> CommandOutcome {
        let ports = await Shell.run("/usr/sbin/networksetup", ["-listallhardwareports"])
        var device = "en0"
        let lines = ports.output.components(separatedBy: "\n")
        if let index = lines.firstIndex(where: { $0.contains("Wi-Fi") || $0.contains("AirPort") }), index + 1 < lines.count,
           let name = lines[index + 1].components(separatedBy: "Device: ").last, !name.isEmpty {
            device = name.trimmingCharacters(in: .whitespaces)
        }
        let r = await Shell.run("/usr/sbin/networksetup", ["-setairportpower", device, on ? "on" : "off"])
        return r.ok && r.error.isEmpty ? .done(on ? "Wi-Fi on" : "Wi-Fi off") : .failed("Couldn't change Wi-Fi: \(r.error.isEmpty ? "unknown error" : r.error)")
    }

    private func startKeepAwake(_ seconds: TimeInterval?) -> CommandOutcome {
        keepAwake?.terminate()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        // -d display, -i system; -w stops it automatically if Duck Keyboard quits.
        var arguments = ["-di", "-w", String(ProcessInfo.processInfo.processIdentifier)]
        if let seconds { arguments += ["-t", String(Int(seconds))] }
        process.arguments = arguments
        do {
            try process.run()
            keepAwake = process
            return .done(seconds.map { "Awake for \(DurationText.spoken($0))" } ?? "Keeping your Mac awake")
        } catch {
            return .failed("Couldn't keep the Mac awake: \(error.localizedDescription)")
        }
    }

    private func automationFailure(_ result: Shell.Result, app: String) -> CommandOutcome {
        if Shell.isAutomationDenied(result) {
            Shell.openAutomationSettings()
            return .failed("macOS blocked Duck Keyboard from controlling \(app). Turn it on in System Settings › Privacy & Security › Automation (opened for you), then try again.")
        }
        return .failed("That didn't work: \(result.error.isEmpty ? "unknown error" : result.error)")
    }

    private func info(_ kind: MacCommand.InfoKind, context: CommandContext) -> String {
        switch kind {
        case .time: return SystemInfo.time()
        case .date: return SystemInfo.date()
        case .battery: return SystemInfo.battery()
        case .storage: return SystemInfo.storage()
        case .memory: return SystemInfo.memory()
        case .uptime: return SystemInfo.uptime()
        case .macOSVersion: return SystemInfo.macOSVersion()
        case .ipAddress: return SystemInfo.ipAddress()
        case .clipboard: return SystemInfo.clipboard()
        case .frontApp:
            if let app = frontApp(context), let name = app.localizedName { return "You're in \(name)." }
            return "I can't tell which app is in front."
        }
    }

    /// "at 5:00 PM", "tomorrow at 9:00 AM", "in 20 minutes".
    static func when(_ date: Date, now: Date = .now) -> String {
        let seconds = date.timeIntervalSince(now)
        if seconds < 3600 { return "in \(DurationText.spoken((seconds / 60).rounded() * 60))" }
        let time = DateFormatter()
        time.dateStyle = .none
        time.timeStyle = .short
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "at \(time.string(from: date))" }
        if calendar.isDateInTomorrow(date) { return "tomorrow at \(time.string(from: date))" }
        let day = DateFormatter()
        day.setLocalizedDateFormatFromTemplate("EEE d MMM")
        return "on \(day.string(from: date)) at \(time.string(from: date))"
    }
}

// MARK: - Places "open …" understands besides apps

struct SettingsPane {
    let name: String
    let url: URL

    private static let panes: [(keys: [String], name: String, id: String)] = [
        (["wifi", "wireless"], "Wi-Fi", "com.apple.wifi-settings-extension"),
        (["bluetooth"], "Bluetooth", "com.apple.BluetoothSettings"),
        (["network", "internet", "vpn"], "Network", "com.apple.Network-Settings.extension"),
        (["display", "displays", "monitor", "screen", "resolution", "night shift"], "Displays", "com.apple.Displays-Settings.extension"),
        (["sound", "audio", "volume", "output", "microphone input"], "Sound", "com.apple.Sound-Settings.extension"),
        (["battery", "power", "energy", "energy saver"], "Battery", "com.apple.Battery-Settings.extension"),
        (["keyboard", "shortcuts", "keyboard shortcuts", "dictation"], "Keyboard", "com.apple.Keyboard-Settings.extension"),
        (["trackpad"], "Trackpad", "com.apple.Trackpad-Settings.extension"),
        (["mouse"], "Mouse", "com.apple.Mouse-Settings.extension"),
        (["notifications", "notification"], "Notifications", "com.apple.Notifications-Settings.extension"),
        (["focus", "do not disturb", "dnd"], "Focus", "com.apple.Focus-Settings.extension"),
        (["privacy", "security", "privacy and security", "permissions"], "Privacy & Security", "com.apple.settings.PrivacySecurity.extension"),
        (["accessibility"], "Accessibility", "com.apple.Accessibility-Settings.extension"),
        (["wallpaper", "background"], "Wallpaper", "com.apple.Wallpaper-Settings.extension"),
        (["appearance", "theme", "dark mode"], "Appearance", "com.apple.Appearance-Settings.extension"),
        (["desktop", "dock", "desktop and dock", "mission control", "stage manager"], "Desktop & Dock", "com.apple.Desktop-Settings.extension"),
        (["control center", "control centre", "menu bar"], "Control Center", "com.apple.ControlCenter-Settings.extension"),
        (["lock screen", "screen saver", "screensaver"], "Lock Screen", "com.apple.Lock-Screen-Settings.extension"),
        (["users", "users and groups", "accounts", "user"], "Users & Groups", "com.apple.Users-Groups-Settings.extension"),
        (["login items", "startup", "startup items", "login"], "Login Items", "com.apple.LoginItems-Settings.extension"),
        (["software update", "update", "updates", "macos update"], "Software Update", "com.apple.Software-Update-Settings.extension"),
        (["storage", "disk"], "Storage", "com.apple.settings.Storage"),
        (["about", "about this mac"], "About", "com.apple.SystemProfiler.AboutExtension"),
        (["general"], "General", "com.apple.systempreferences.GeneralSettings"),
        (["date and time", "date & time", "time", "clock", "date"], "Date & Time", "com.apple.Date-Time-Settings.extension"),
        (["sharing", "airdrop", "airplay"], "Sharing", "com.apple.Sharing-Settings.extension"),
        (["printers", "printer", "printers and scanners", "scanner"], "Printers & Scanners", "com.apple.Print-Scan-Settings.extension"),
        (["screen time"], "Screen Time", "com.apple.Screen-Time-Settings.extension"),
        (["siri", "apple intelligence", "apple intelligence and siri"], "Siri", "com.apple.Siri-Settings.extension"),
        (["passwords"], "Passwords", "com.apple.Passwords-Settings.extension"),
        (["internet accounts", "mail accounts"], "Internet Accounts", "com.apple.Internet-Accounts-Settings.extension"),
        (["touch id", "touch id and password", "fingerprint"], "Touch ID & Password", "com.apple.Touch-ID-Settings.extension"),
        (["language", "language and region", "region", "languages"], "Language & Region", "com.apple.Localization-Settings.extension"),
    ]

    /// "wifi settings", "settings for bluetooth", "bluetooth". Needs the word settings/preferences,
    /// except for a few that aren't app names (so "open display" stays an app search).
    static func match(_ target: String) -> SettingsPane? {
        var t = target
        var saidSettings = false
        for word in [" settings", " preferences", " preference", " panel", " pane", " setting", " options"] where t.hasSuffix(word) {
            t = String(t.dropLast(word.count)); saidSettings = true
        }
        for word in ["settings for ", "settings of ", "preferences for ", "system settings for "] where t.hasPrefix(word) {
            t = String(t.dropFirst(word.count)); saidSettings = true
        }
        if t.hasPrefix("the ") { t = String(t.dropFirst(4)) }
        if t.hasPrefix("my ") { t = String(t.dropFirst(3)) }
        t = t.replacingOccurrences(of: "&", with: "and")
        let alwaysPane: Set<String> = ["wifi", "bluetooth"]
        guard saidSettings || alwaysPane.contains(t) else { return nil }
        guard let pane = panes.first(where: { $0.keys.contains(t) }),
              let url = URL(string: "x-apple.systempreferences:\(pane.id)") else { return nil }
        return SettingsPane(name: pane.name, url: url)
    }
}

struct Folder {
    let name: String
    let url: URL

    static func match(_ target: String) -> Folder? {
        var t = target
        var saidFolder = false
        for word in [" folder", " directory"] where t.hasSuffix(word) { t = String(t.dropLast(word.count)); saidFolder = true }
        if t.hasPrefix("the ") { t = String(t.dropFirst(4)) }
        if t.hasPrefix("my ") { t = String(t.dropFirst(3)) }
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let folders: [(keys: [String], name: String, url: URL, needsWord: Bool)] = [
            (["downloads", "download"], "Downloads", home.appendingPathComponent("Downloads"), false),
            (["desktop"], "Desktop", home.appendingPathComponent("Desktop"), false),
            (["documents", "document", "docs"], "Documents", home.appendingPathComponent("Documents"), false),
            (["home", "user", "home directory"], "Home", home, true),
            (["applications", "apps"], "Applications", URL(fileURLWithPath: "/Applications"), false),
            (["pictures", "photos"], "Pictures", home.appendingPathComponent("Pictures"), true),
            (["music"], "Music folder", home.appendingPathComponent("Music"), true),
            (["movies", "videos"], "Movies", home.appendingPathComponent("Movies"), true),
            (["trash", "bin", "recycle bin"], "Trash", home.appendingPathComponent(".Trash"), false),
            (["icloud", "icloud drive"], "iCloud Drive", home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs"), false),
            (["airdrop"], "AirDrop", URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app/Contents/Applications/AirDrop.app"), false),
        ]
        guard let folder = folders.first(where: { $0.keys.contains(t) && (saidFolder || !$0.needsWord) }) else { return nil }
        guard fm.fileExists(atPath: folder.url.path) else { return nil }
        return Folder(name: folder.name, url: folder.url)
    }
}

struct Website {
    let name: String
    let url: URL

    private static let sites: [String: (String, String)] = [
        "youtube": ("YouTube", "https://www.youtube.com"), "you tube": ("YouTube", "https://www.youtube.com"),
        "gmail": ("Gmail", "https://mail.google.com"), "google mail": ("Gmail", "https://mail.google.com"),
        "google": ("Google", "https://www.google.com"), "github": ("GitHub", "https://github.com"),
        "git hub": ("GitHub", "https://github.com"), "netflix": ("Netflix", "https://www.netflix.com"),
        "amazon": ("Amazon", "https://www.amazon.com"), "twitter": ("X", "https://x.com"),
        "linkedin": ("LinkedIn", "https://www.linkedin.com"), "linked in": ("LinkedIn", "https://www.linkedin.com"),
        "facebook": ("Facebook", "https://www.facebook.com"), "instagram": ("Instagram", "https://www.instagram.com"),
        "reddit": ("Reddit", "https://www.reddit.com"), "wikipedia": ("Wikipedia", "https://www.wikipedia.org"),
        "chatgpt": ("ChatGPT", "https://chatgpt.com"), "chat gpt": ("ChatGPT", "https://chatgpt.com"),
        "claude": ("Claude", "https://claude.ai"), "google drive": ("Google Drive", "https://drive.google.com"),
        "drive": ("Google Drive", "https://drive.google.com"), "google docs": ("Google Docs", "https://docs.google.com"),
        "google sheets": ("Google Sheets", "https://sheets.google.com"), "google calendar": ("Google Calendar", "https://calendar.google.com"),
        "google maps": ("Google Maps", "https://maps.google.com"), "google meet": ("Google Meet", "https://meet.google.com"),
        "stack overflow": ("Stack Overflow", "https://stackoverflow.com"), "stackoverflow": ("Stack Overflow", "https://stackoverflow.com"),
        "hacker news": ("Hacker News", "https://news.ycombinator.com"), "whatsapp": ("WhatsApp Web", "https://web.whatsapp.com"),
        "whatsapp web": ("WhatsApp Web", "https://web.whatsapp.com"), "spotify": ("Spotify", "https://open.spotify.com"),
        "hotstar": ("JioHotstar", "https://www.hotstar.com"), "prime video": ("Prime Video", "https://www.primevideo.com"),
        "flipkart": ("Flipkart", "https://www.flipkart.com"), "hugging face": ("Hugging Face", "https://huggingface.co"),
        "huggingface": ("Hugging Face", "https://huggingface.co"), "outlook web": ("Outlook", "https://outlook.live.com"),
    ]

    static func match(_ target: String) -> Website? {
        var t = target
        for tail in [" website", " site", " web site", " in the browser", " in browser"] where t.hasSuffix(tail) { t = String(t.dropLast(tail.count)) }
        guard let entry = sites[t], let url = URL(string: entry.1) else { return nil }
        return Website(name: entry.0, url: url)
    }

    /// "youtube.com", "apple.com/mac", "news.ycombinator.com".
    static func domainURL(_ target: String) -> URL? {
        let t = target.replacingOccurrences(of: " ", with: "")
        guard t.range(of: #"^(https?://)?[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}(/\S*)?$"#, options: .regularExpression) != nil else { return nil }
        return URL(string: t.hasPrefix("http") ? t : "https://\(t)")
    }
}
