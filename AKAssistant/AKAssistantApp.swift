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
                .frame(minWidth: 820, minHeight: 540)
        }
        .modelContainer(appState.container)
        .defaultSize(width: 960, height: 620)

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

    /// Closing the window keeps the app (and the hotkey) running in the background.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
