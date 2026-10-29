import SwiftUI
import AppKit
import SwiftData

@main
struct AKAssistantApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // @State holds the @Observable model for the app's lifetime.
    @State private var appState = AppState.shared

    var body: some Scene {
        // Main window: opened from the menu bar. Shows history, models, settings.
        // The Dock icon appears only while this window is open (see AppDelegate).
        Window("Duck Keyboard", id: WindowID.main) {
            RootView()
                .environment(appState)
                .environment(appState.preferences)
                .environment(appState.modelManager)
                .frame(minWidth: 900, minHeight: 560)
        }
        .modelContainer(appState.container)
        .defaultSize(width: 1100, height: 700)
        // Once set up, start quietly in the menu bar (e.g. at login) instead of opening this window.
        // Click "Open Duck Keyboard" in the menu bar to show it.
        .defaultLaunchBehavior(appState.preferences.onboarded ? .suppressed : .presented)
        .restorationBehavior(.disabled)

        // Menu bar icon: a panel with status, the keys, meeting control, recent entries and shortcuts.
        MenuBarExtra {
            MenuBarContent()
                .environment(appState)
                .environment(appState.preferences)
                .environment(appState.modelManager)
                .modelContainer(appState.container)
        } label: {
            if appState.meetings.isRecording {
                // Red and softly glowing, so a long meeting recording is noticeable but out of the way.
                Image(nsImage: MenuBarIcon.recording(bright: appState.menuBarGlowBright))
                    .help("Duck Keyboard is recording a meeting")
            } else {
                Image(systemName: appState.menuBarSymbol)
            }
        }
        // A real panel (not a plain menu) so it can show status, keycaps and click-to-copy rows.
        .menuBarExtraStyle(.window)
    }
}

enum WindowID {
    static let main = "main"
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowObservers: [NSObjectProtocol] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Menu-bar app: no Dock icon while it runs in the background (LSUIElement is also set in Info.plist).
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        observeMainWindow()
        MainActor.assumeIsolated {
            AppState.shared.start()
        }
        // On first launch the onboarding window is presented straight away.
        DispatchQueue.main.async { MainActor.assumeIsolated { self.updateDockPresence() } }
    }

    /// Make sure meetings and history are on disk before quitting.
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppState.shared.restoreSystemAudio()   // never leave the Mac muted
            AppState.shared.saveData()
        }
    }

    /// Closing the window keeps the app (and the hotkey) running in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Dock icon only while the full window is open

    /// Show the Dock icon (and app menu / Cmd-Tab entry) while the main window is open,
    /// and drop back to menu-bar-only when it closes.
    private func observeMainWindow() {
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification] {
            windowObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let window = note.object as? NSWindow, Self.isFullWindow(window) else { return }
                    self?.updateDockPresence()
                }
            })
        }
        windowObservers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let window = note.object as? NSWindow, Self.isFullWindow(window) else { return }
                // Wait until the window has actually gone before checking.
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.updateDockPresence() } }
            }
        })
    }

    @MainActor
    private func updateDockPresence() {
        let hasFullWindow = NSApp.windows.contains { Self.isFullWindow($0) && $0.isVisible }
        let wanted: NSApplication.ActivationPolicy = hasFullWindow ? .regular : .accessory
        guard NSApp.activationPolicy() != wanted else { return }
        NSApp.setActivationPolicy(wanted)
        if wanted == .regular {
            // Re-activate so the app's menu bar shows up right away.
            NSApp.activate()
        }
    }

    /// A real app window (main window), not the floating island panel, alerts, sheets or the menu bar dropdown.
    @MainActor
    private static func isFullWindow(_ window: NSWindow) -> Bool {
        !(window is NSPanel)
            && !String(describing: type(of: window)).contains("MenuBarExtra")   // the menu bar panel
            && window.styleMask.contains(.titled)
            && window.sheetParent == nil
            && window.canBecomeMain
    }
}

/// The menu bar icon while a meeting records: a red dot with a soft red glow. Menu bar labels
/// are drawn as monochrome templates, so the colour has to be baked into a non-template image.
@MainActor
enum MenuBarIcon {
    private static var cache: [Bool: NSImage] = [:]

    static func recording(bright: Bool) -> NSImage {
        if let image = cache[bright] { return image }
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { rect in
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.systemRed]))
            guard let symbol = NSImage(systemSymbolName: "record.circle.fill",
                                       accessibilityDescription: "Recording a meeting")?
                .withSymbolConfiguration(config) else { return false }
            let glow = NSShadow()
            glow.shadowColor = NSColor.systemRed.withAlphaComponent(bright ? 0.85 : 0.3)
            glow.shadowBlurRadius = bright ? 4 : 1.5
            glow.shadowOffset = .zero
            glow.set()
            let size = symbol.size
            let frame = NSRect(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2,
                               width: size.width, height: size.height)
            symbol.draw(in: frame, from: .zero, operation: .sourceOver, fraction: bright ? 1 : 0.75)
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Recording a meeting"
        cache[bright] = image
        return image
    }
}
