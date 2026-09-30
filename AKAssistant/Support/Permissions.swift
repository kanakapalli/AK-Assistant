import AVFoundation
import AppKit
import ApplicationServices

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

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
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
