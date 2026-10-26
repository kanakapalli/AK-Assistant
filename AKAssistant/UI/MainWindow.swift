import SwiftUI
import SwiftData

/// Shows onboarding on first launch, then the main window.
struct RootView: View {
    @Environment(Preferences.self) private var preferences

    var body: some View {
        if preferences.onboarded {
            MainView()
        } else {
            OnboardingView()
        }
    }
}

enum SidebarItem: String, CaseIterable, Identifiable {
    case history = "History"
    case meetings = "Meetings"
    case learn = "Learn"
    case settings = "Settings"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .history: return "clock.arrow.circlepath"
        case .meetings: return "person.2.wave.2"
        case .learn: return "graduationcap"
        case .settings: return "gearshape"
        }
    }
}

struct MainView: View {
    @Environment(AppState.self) private var appState
    @Environment(Preferences.self) private var preferences

    var body: some View {
        // The selection lives in AppState so the menu bar and Settings can jump to Learn.
        @Bindable var appState = appState

        NavigationSplitView {
            List(SidebarItem.allCases, selection: $appState.sidebarSelection) { item in
                // One row shape for every item: swapping the row's view when the "New" badge goes
                // away made the List drop its selection, so Learn jumped straight back to History.
                Label(item.rawValue, systemImage: item.symbol)
                    .badge(item == .learn && !preferences.seenLearn ? Text("New") : nil)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
            .safeAreaInset(edge: .bottom) { StatusFooter().padding(12) }
        } detail: {
            switch appState.sidebarSelection ?? .history {
            case .history: HistoryView()
            case .meetings: MeetingsView()
            case .learn: LearnView()
            case .settings: SettingsView()
            }
        }
        // Clicking empty space in the sidebar deselects; keep showing the page you were on.
        .onChange(of: appState.sidebarSelection) { old, new in
            if new == nil, let old { appState.sidebarSelection = old }
        }
    }
}

/// Current model, hotkey and permission health, at the bottom of the sidebar.
struct StatusFooter: View {
    @Environment(Preferences.self) private var preferences
    @Environment(ModelManager.self) private var modelManager

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(preferences.selectedModel.name, systemImage: "cpu")
            Label("Hold \(preferences.hotkey.title)", systemImage: "keyboard")
            if preferences.meetingDoubleTap {
                Label("Double-tap for a meeting", systemImage: "person.2.wave.2")
            }
            if preferences.assistantEnabled {
                Label("AI: \(preferences.chatModel.name)", systemImage: "sparkles")
                Label("Hold \(preferences.assistantHotkey.title)", systemImage: "keyboard.badge.ellipsis")
            }
            if !Permissions.accessibilityGranted {
                Label("Accessibility off", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
