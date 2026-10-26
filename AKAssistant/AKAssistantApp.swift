import SwiftUI
import SwiftData

@main
struct AKAssistantApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // @State holds the @Observable model for the app's lifetime.
    @State private var appState = AppState.shared

    var body: some Scene {
        // Main window: opened from the Dock icon or the menu bar. Shows history, models, settings.
        Window("AK Assistant", id: WindowID.main) {
            RootView()
                .environment(appState)
                .environment(appState.preferences)
                .environment(appState.modelManager)
                .frame(minWidth: 900, minHeight: 560)
        }
        .modelContainer(appState.container)
        .defaultSize(width: 1100, height: 700)
        // Once set up, start quietly in the menu bar (e.g. at login) instead of opening this window.
        // Click the Dock icon or "Open AK Assistant" in the menu bar to show it.
        .defaultLaunchBehavior(appState.preferences.onboarded ? .suppressed : .presented)
        .restorationBehavior(.disabled)

        // Menu bar icon: status, recent dictations, quick actions.
        MenuBarExtra {
            MenuBarContent()
                .environment(appState)
                .environment(appState.preferences)
                .environment(appState.modelManager)
                .modelContainer(appState.container)
        } label: {
            Image(systemName: appState.menuBarSymbol)
        }
    }
}

enum WindowID {
    static let main = "main"
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Regular app: Dock icon + main window. Dictation keeps working while other apps are in front.
        NSApp.setActivationPolicy(.regular)
        MainActor.assumeIsolated {
            AppState.shared.start()
        }
    }

    /// Make sure meetings and history are on disk before quitting.
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppState.shared.restoreSystemAudio()   // never leave the Mac muted
            AppState.shared.saveData()
        }
    }

    /// Closing the window keeps the app (and the hotkey) running in the background.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
