import AVFoundation
import AppKit
import ApplicationServices
import Carbon
import Carbon.HIToolbox
import UserNotifications

enum Permissions {
    static var microphoneGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Needed to watch the push-to-talk key globally and to paste into other apps.
    static var accessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system prompt that points the user to System Settings > Privacy & Security > Accessibility.
    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Separate from Accessibility: macOS also checks whether the app may *send* keystrokes (⌘V).
    /// It's normally granted together with Accessibility, but can be missing for a rebuilt copy.
    static var canSendKeystrokes: Bool {
        CGPreflightPostEventAccess()
    }

    static func requestSendKeystrokes() {
        _ = CGRequestPostEventAccess()
    }

    /// Where the running copy of the app lives. macOS grants permissions per copy, so this shows
    /// which one System Settings needs to list.
    static var runningAppPath: String {
        Bundle.main.bundlePath
    }

    /// One line for the log so a paste problem can be traced to the right permission.
    static var summary: String {
        "mic=\(microphoneGranted) accessibility=\(accessibilityGranted) sendKeys=\(canSendKeystrokes) inputMonitoring=\(inputMonitoringGranted) screen=\(screenCaptureGranted) app=\(runningAppPath)"
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Meetings use it to record the Mac's audio (the other people on a call). The video is ignored.
    /// macOS may only report a new grant after Duck Keyboard restarts.
    static var screenCaptureGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func requestScreenCapture() {
        _ = CGRequestScreenCaptureAccess()
    }

    static func openScreenCaptureSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Input Monitoring. Global key monitors work with Accessibility alone on most Macs, but some
    /// setups (and managed Macs) also require this.
    static var inputMonitoringGranted: Bool {
        CGPreflightListenEventAccess()
    }

    static func requestInputMonitoring() {
        _ = CGRequestListenEventAccess()
    }

    static func openInputMonitoringSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    /// The app holding "Secure Keyboard Entry" (a password field, Terminal, a password manager).
    /// While one does, macOS hides key presses from every other app, so hotkeys can't be seen.
    static var secureInputApp: String? {
        guard IsSecureEventInputEnabled() else { return nil }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        if let pid = session?["kCGSSessionSecureInputPID"] as? Int,
           let app = NSRunningApplication(processIdentifier: pid_t(pid)) {
            return app.localizedName ?? "another app"
        }
        return "another app"
    }

    // MARK: - Notifications (timers and reminders)

    enum Grant: Equatable {
        case granted, denied, notAsked
    }

    static func notificationStatus() async -> Grant {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional: return .granted
        case .denied: return .denied
        default: return .notAsked
        }
    }

    /// Shows the macOS "Allow notifications?" prompt the first time; afterwards opens System Settings.
    static func requestNotifications() async -> Bool {
        if await notificationStatus() == .denied {
            openNotificationSettings()
            return false
        }
        return (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    static func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Automation (Mac commands: dark mode, Empty Trash, restart…)

    /// The apps Mac commands talk to through AppleScript.
    static let automationTargets = ["com.apple.systemevents", "com.apple.finder"]

    /// Whether Duck Keyboard may control the apps Mac commands use. With `ask`, macOS shows its
    /// "Duck Keyboard wants to control…" prompt for each app not decided yet. Blocks while the
    /// prompt is up, so this runs off the main thread.
    static func automationStatus(ask: Bool) async -> Grant {
        await Task.detached(priority: .userInitiated) {
            var result: Grant = .granted
            for bundleID in Permissions.automationTargets {
                var status = Permissions.automationStatus(bundleID: bundleID, ask: ask)
                if status == OSStatus(procNotFound), ask {
                    // System Events only runs on demand; start it so macOS can ask.
                    Permissions.launchSystemEvents()
                    try? await Task.sleep(for: .seconds(1))
                    status = Permissions.automationStatus(bundleID: bundleID, ask: ask)
                }
                switch status {
                case OSStatus(noErr): continue
                case OSStatus(errAEEventNotPermitted): return .denied
                default: result = .notAsked   // not asked yet, or the app isn't running
                }
            }
            return result
        }.value
    }

    private static func automationStatus(bundleID: String, ask: Bool) -> OSStatus {
        var target = AEAddressDesc()
        let bytes = Array(bundleID.utf8)
        let created = bytes.withUnsafeBytes { buffer in
            AECreateDesc(DescType(typeApplicationBundleID), buffer.baseAddress, buffer.count, &target)
        }
        guard created == OSErr(noErr) else { return OSStatus(created) }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(&target, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
    }

    private static func launchSystemEvents() {
        let url = URL(fileURLWithPath: "/System/Library/CoreServices/System Events.app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration, completionHandler: nil)
    }

    static func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Everything dictation needs

    /// Microphone, Accessibility and Send keystrokes: without all three, dictation can't paste.
    static var dictationReady: Bool {
        microphoneGranted && accessibilityGranted && canSendKeystrokes
    }

    /// macOS often reports Send keystrokes, Input Monitoring and Screen Recording to a running app
    /// only after it restarts. Quits and reopens this copy (onboarding resumes on the same step).
    static func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }

    static func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}

enum Sounds {
    enum Cue { case start, stop }

    static func play(_ cue: Cue, enabled: Bool) {
        guard enabled else { return }
        let name = cue == .start ? "Tink" : "Pop"
        NSSound(named: NSSound.Name(name))?.play()
    }
}
