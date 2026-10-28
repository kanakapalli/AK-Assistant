import AVFoundation
import AppKit
import ApplicationServices
import Carbon.HIToolbox

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
        "mic=\(microphoneGranted) accessibility=\(accessibilityGranted) sendKeys=\(canSendKeystrokes) app=\(runningAppPath)"
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
