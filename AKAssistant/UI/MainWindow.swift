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
    case models = "Models"
    case settings = "Settings"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .history: return "clock.arrow.circlepath"
        case .models: return "square.and.arrow.down.on.square"
        case .settings: return "gearshape"
        }
    }
}

struct MainView: View {
    @State private var selection: SidebarItem? = .history

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(item.rawValue, systemImage: item.symbol).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
            .safeAreaInset(edge: .bottom) { StatusFooter().padding(12) }
        } detail: {
            switch selection ?? .history {
            case .history: HistoryView()
            case .models: ModelsView()
            case .settings: SettingsView()
            }
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
