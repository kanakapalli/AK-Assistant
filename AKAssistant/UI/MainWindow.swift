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
            // Brand, list and footer are stacked in a plain VStack. Insetting the List's top safe area
            // (safeAreaInset(edge: .top)) made the sidebar list slide up under the title bar.
            VStack(spacing: 0) {
                SidebarBrand()
                    .padding(.horizontal, 14)
                    .padding(.top, 6)
                    .padding(.bottom, 6)

                List(SidebarItem.allCases, selection: $appState.sidebarSelection) { item in
                    // One row shape for every item: swapping the row's view when the "New" badge goes
                    // away made the List drop its selection, so Learn jumped straight back to History.
                    Label(item.rawValue, systemImage: item.symbol)
                        .badge(item == .learn && !preferences.seenLearn ? Text("New") : nil)
                        .tag(item)
                }
                .scrollBounceBehavior(.basedOnSize)

                StatusFooter()
                    .padding(10)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            switch appState.sidebarSelection ?? .history {
            case .history: HistoryView()
            case .meetings: MeetingsView()
            case .learn: LearnView()
            case .settings: SettingsView()
            }
        }
        .tint(Duck.orange)
        // Clicking empty space in the sidebar deselects; keep showing the page you were on.
        .onChange(of: appState.sidebarSelection) { old, new in
            if new == nil, let old { appState.sidebarSelection = old }
        }
    }
}

/// App icon and name at the top of the sidebar.
private struct SidebarBrand: View {
    var body: some View {
        HStack(spacing: 10) {
            BrandMark(size: 32)
            VStack(alignment: .leading, spacing: 0) {
                Text("Duck Keyboard")
                    .font(.system(.headline, design: .rounded).weight(.bold))
                Text("Private, on this Mac")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

/// The keys, the models and permission health, at the bottom of the sidebar.
struct StatusFooter: View {
    @Environment(AppState.self) private var appState
    @Environment(Preferences.self) private var preferences

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            keyRow(preferences.hotkey, "Dictate", detail: preferences.selectedModel.name)
            if preferences.assistantEnabled, preferences.assistantHotkey != .off {
                keyRow(preferences.assistantHotkey, "Ask AI", detail: preferences.chatModel.name)
            }
            if preferences.meetingDoubleTap {
                HStack(spacing: 6) {
                    DuckKeycap(preferences.hotkey.keycapLabel)
                    DuckKeycap(preferences.hotkey.keycapLabel)
                    Text("Meeting").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !Permissions.accessibilityGranted {
                Button {
                    appState.openSettings(.permissions)
                } label: {
                    Label("Accessibility is off", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Duck.warning)
                }
                .buttonStyle(.plain)
                .help("Open Settings › Permissions")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .duckCard(padding: 10)
    }

    private func keyRow(_ key: HotkeyChoice, _ title: String, detail: String) -> some View {
        HStack(spacing: 8) {
            DuckKeycap(key.keycapLabel)
                .help("Hold \(key.title)")
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.caption.weight(.semibold))
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}
