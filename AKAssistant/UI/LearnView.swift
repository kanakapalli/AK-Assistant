import SwiftUI
import UserNotifications
import KeyboardShortcuts

// Learn: a hands-on guide to Duck Keyboard.
//
//  • Get started   – a checklist you complete by actually using the app (permissions, models,
//                    a practice dictation, a first question, a first command, a first rewrite).
//                    Ticks itself off.
//  • Commands      – everything you can say, as clickable pills (click = try it now).
//  • Features      – short cards per feature, with "Show more" and a button to the right screen.
//  • Tips & fixes  – live permission status and answers to common problems, with Fix buttons.
//
// The toolbar search looks through all four at once.

enum LearnTab: String, CaseIterable, Identifiable {
    case start = "Get started"
    case commands = "Commands"
    case features = "Features"
    case help = "Tips & fixes"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .start: return "flag.checkered"
        case .commands: return "text.bubble"
        case .features: return "square.grid.2x2"
        case .help: return "lifepreserver"
        }
    }
}

struct LearnView: View {
    @Environment(Preferences.self) private var preferences
    @State private var tab: LearnTab = .start
    @State private var search = ""

    var body: some View {
        VStack(spacing: 0) {
            if search.isEmpty {
                DuckTabBar(tabs: LearnTab.allCases, selection: $tab, style: .pills,
                           title: { $0.rawValue }, symbol: { $0.symbol })
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                Divider()
            }

            ScrollView {
                Group {
                    if !search.isEmpty {
                        LearnSearchResults(query: search.trimmingCharacters(in: .whitespaces))
                    } else {
                        switch tab {
                        case .start: GetStartedTab(showTab: { tab = $0 })
                        case .commands: CommandsTab()
                        case .features: FeaturesTab()
                        case .help: HelpTab()
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .id(tab)   // each tab starts at the top
        }
        .navigationTitle("Learn")
        .searchable(text: $search, placement: .toolbar, prompt: "Search commands and features")
        .onDisappear { preferences.seenLearn = true }   // the sidebar's "New" badge goes once you've looked
    }
}

// MARK: - Get started

private enum LearnStep: Int, CaseIterable, Identifiable {
    case permissions, models, dictate, ask, command, rewrite
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .permissions: return "Allow the microphone and Accessibility"
        case .models: return "Download a speech model"
        case .dictate: return "Dictate your first sentence"
        case .ask: return "Ask the AI a question"
        case .command: return "Give your Mac a command"
        case .rewrite: return "Fix a sentence with a writing tool"
        }
    }
}

private struct GetStartedTab: View {
    @Environment(AppState.self) private var appState
    @Environment(Preferences.self) private var preferences
    @Environment(ModelManager.self) private var modelManager
    let showTab: (LearnTab) -> Void

    @AppStorage("learn.didDictate") private var didDictate = false
    @AppStorage("learn.didAsk") private var didAsk = false
    @AppStorage("learn.didCommand") private var didCommand = false
    @AppStorage("learn.didRewrite") private var didRewrite = false
    @State private var micGranted = Permissions.microphoneGranted
    @State private var axGranted = Permissions.accessibilityGranted
    /// A step the user clicked open; otherwise the first unfinished one is open.
    @State private var opened: LearnStep?

    private func isDone(_ step: LearnStep) -> Bool {
        switch step {
        case .permissions: return micGranted && axGranted
        case .models: return modelManager.isDownloaded(preferences.selectedModel)
        case .dictate: return didDictate
        case .ask: return didAsk
        case .command: return didCommand
        case .rewrite: return didRewrite
        }
    }

    private var doneCount: Int { LearnStep.allCases.filter { isDone($0) }.count }
    private var firstUnfinished: LearnStep? { LearnStep.allCases.first { !isDone($0) } }
    private var current: LearnStep? { opened ?? firstUnfinished }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header

            VStack(spacing: 10) {
                ForEach(LearnStep.allCases) { step in
                    StepCard(
                        number: step.rawValue + 1,
                        title: step.title,
                        subtitle: subtitle(for: step),
                        done: isDone(step),
                        expanded: current == step,
                        onToggle: { toggle(step) }
                    ) {
                        stepBody(step)
                    }
                }
            }

            if doneCount == LearnStep.allCases.count { allSetBanner }

            HowItWorks()
        }
        .task {
            // Permissions can change in System Settings while this page is open.
            while !Task.isCancelled {
                micGranted = Permissions.microphoneGranted
                axGranted = Permissions.accessibilityGranted
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
        .onChange(of: appState.reply?.question) { _, question in
            // Any question that reached the AI (not a command) counts.
            if let question, !question.isEmpty, appState.reply?.command == nil {
                didAsk = true
                opened = nil
            }
        }
        .onChange(of: appState.lastCommand?.at) { _, at in
            if at != nil {
                didCommand = true
                opened = nil
            }
        }
        .onChange(of: appState.lastRewriteAt) { _, at in
            if at != nil {
                didRewrite = true
                opened = nil
            }
        }
    }

    private func toggle(_ step: LearnStep) {
        if current == step {
            // Closing it opens the next unfinished step instead (or nothing when all are done).
            opened = LearnStep.allCases.first(where: { !isDone($0) && $0 != step })
        } else {
            opened = step
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            ProgressRing(progress: Double(doneCount) / Double(LearnStep.allCases.count))
                .frame(width: 64, height: 64)
                .overlay(
                    Text("\(doneCount)/\(LearnStep.allCases.count)")
                        .font(.headline.monospacedDigit())
                )
            VStack(alignment: .leading, spacing: 4) {
                Text(doneCount == LearnStep.allCases.count ? "You know the basics" : "Learn Duck Keyboard in a minute")
                    .font(.largeTitle.weight(.bold))
                Text("Each step ticks itself off when you do it, so just follow along.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func subtitle(for step: LearnStep) -> String {
        switch step {
        case .permissions:
            if isDone(step) { return "Both allowed" }
            let missing: [String] = [micGranted ? nil : "Microphone", axGranted ? nil : "Accessibility"].compactMap { $0 }
            return missing.joined(separator: " and ") + " still needed"
        case .models:
            let name = preferences.selectedModel.name
            return isDone(step) ? "\(name) is ready" : "\(name) isn't downloaded yet"
        case .dictate:
            return isDone(step) ? "Nice, that's dictation" : "Hold \(keyName(preferences.hotkey)), talk, let go"
        case .ask:
            return isDone(step) ? "The AI answered you" : "Hold \(keyName(preferences.assistantHotkey)) and ask anything"
        case .command:
            return isDone(step) ? "Your Mac did what you said" : "Same AI key: “Open Calculator”"
        case .rewrite:
            return isDone(step) ? "Your text was rewritten in place" : "Click in a text field, press \(writingShortcut(for: "grammar"))"
        }
    }

    @ViewBuilder private func stepBody(_ step: LearnStep) -> some View {
        switch step {
        case .permissions:
            VStack(alignment: .leading, spacing: 8) {
                Text("Duck Keyboard needs to hear you, and to type into other apps.")
                    .foregroundStyle(.secondary)
                StatusRow(title: "Microphone", detail: "Only used while you hold a hotkey", ok: micGranted, fixTitle: "Allow") {
                    Task {
                        micGranted = await Permissions.requestMicrophone()
                        if !micGranted { Permissions.openMicrophoneSettings() }
                    }
                }
                StatusRow(title: "Accessibility", detail: "Lets the hotkey work everywhere and paste your text", ok: axGranted, fixTitle: "Open Settings") {
                    Permissions.requestAccessibility()
                    Permissions.openAccessibilitySettings()
                }
            }
        case .models:
            VStack(alignment: .leading, spacing: 8) {
                StatusRow(title: "Speech to text: \(preferences.selectedModel.name)", detail: "Needed for everything",
                          ok: modelManager.isDownloaded(preferences.selectedModel), fixTitle: "Choose a model") {
                    appState.openSettings(.models)
                }
                StatusRow(title: "AI: \(preferences.chatModel.name)", detail: "Needed for questions (Mac commands work without it)",
                          ok: modelManager.isDownloaded(preferences.chatModel), fixTitle: "Choose a model") {
                    appState.openSettings(.models)
                }
            }
        case .dictate:
            VStack(alignment: .leading, spacing: 10) {
                InstructionLine(key: keyName(preferences.hotkey), text: "Click in the box below, hold the key, say “Hello from my Mac”, then let go.")
                PracticeBox {
                    didDictate = true
                    opened = nil
                }
                Text("Tip: press Esc while you're still holding the key to cancel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .ask:
            VStack(alignment: .leading, spacing: 10) {
                InstructionLine(key: keyName(preferences.assistantHotkey), text: "Hold the key, ask a question out loud, then let go. The answer appears at the top of the screen.")
                Text("Ideas to try:").font(.caption).foregroundStyle(.secondary)
                FlowLayout(spacing: 6) {
                    ForEach(["What's a fun fact about octopuses?", "How do I say thank you in Japanese?", "Give me three names for a cat café"], id: \.self) { idea in
                        Text("“\(idea)”")
                            .font(.callout)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Duck.assistant.opacity(0.1), in: Capsule())
                    }
                }
                if !preferences.assistantEnabled {
                    Label("The AI key is off. Pick one in Settings › AI Assistant.", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                }
            }
        case .command:
            VStack(alignment: .leading, spacing: 10) {
                InstructionLine(key: keyName(preferences.assistantHotkey), text: "Use the same AI key, but tell it to do something: “Open Calculator”.")
                HStack(spacing: 10) {
                    Button {
                        appState.tryCommand("Open Calculator")
                    } label: {
                        Label("Or click to try it", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!preferences.macCommandsEnabled || appState.isBusy)
                    Button("See all commands") { showTab(.commands) }
                }
                if !preferences.macCommandsEnabled {
                    HStack {
                        Label("Mac commands are turned off.", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                        Button("Turn on") { preferences.macCommandsEnabled = true }
                    }
                }
            }
        case .rewrite:
            VStack(alignment: .leading, spacing: 10) {
                InstructionLine(key: writingShortcut(for: "grammar"), text: "Click in the box below, then press the shortcut. The mistakes are fixed and the text is pasted back.")
                WritingPracticeBox()
                FlowLayout(spacing: 6) {
                    ForEach(preferences.textActions.filter(\.enabled)) { action in
                        HStack(spacing: 6) {
                            KeyCap(writingShortcut(for: action.id), compact: true)
                            Text(action.title).font(.callout)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Duck.writing.opacity(0.1), in: Capsule())
                    }
                }
                HStack(spacing: 10) {
                    Text("Try the others on the same text, or change their prompts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Writing tool settings") { appState.openSettings(.grammar) }
                        .controlSize(.small)
                }
                if !preferences.grammarFixEnabled {
                    HStack {
                        Label("Writing tools are turned off.", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                        Button("Turn on") { preferences.grammarFixEnabled = true }
                    }
                }
            }
        }
    }

    private var allSetBanner: some View {
        HStack(spacing: 14) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 34))
                .foregroundStyle(.green.gradient)
                .symbolEffect(.bounce, value: doneCount)
            VStack(alignment: .leading, spacing: 2) {
                Text("You're all set").font(.title3.weight(.semibold))
                Text("Next, see the 70+ things you can say, or explore meetings, writing tools and the rest.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Browse commands") { showTab(.commands) }
                .buttonStyle(.borderedProminent)
            Button("Features") { showTab(.features) }
            Menu {
                Button("Start the tutorial again") {
                    didDictate = false
                    didAsk = false
                    didCommand = false
                    didRewrite = false
                    opened = nil
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(16)
        .background(Color.green.opacity(0.08), in: learnCardShape)
        .overlay(learnCardShape.strokeBorder(Color.green.opacity(0.25)))
    }
}

/// A text box with mistakes in it, to try a writing tool on.
private struct WritingPracticeBox: View {
    @State private var text = "i has went to the shop yesterday and buyed three apple, they was very tasty"
    @FocusState private var focused: Bool

    var body: some View {
        TextEditor(text: $text)
            .font(.title3)
            .scrollContentBackground(.hidden)
            .focused($focused)
            .padding(8)
            .frame(height: 90)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(focused ? Duck.writing : Color.primary.opacity(0.15), lineWidth: focused ? 2 : 1)
            )
    }
}

/// A text box to practise dictation in. Calls `onText` once something has been dictated into it.
private struct PracticeBox: View {
    let onText: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(.title3)
                .scrollContentBackground(.hidden)
                .focused($focused)
                .padding(8)
            if text.isEmpty {
                Text(focused ? "Now hold the key and talk…" : "Click here first")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: 90)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(focused ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: focused ? 2 : 1)
        )
        .onChange(of: text) { _, new in
            if new.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 { onText() }
        }
    }
}

private struct StepCard<Content: View>: View {
    let number: Int
    let title: String
    let subtitle: String
    let done: Bool
    let expanded: Bool
    let onToggle: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: { withAnimation(.snappy) { onToggle() } }) {
                HStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(done ? Color.green : (expanded ? Color.accentColor : Color.primary.opacity(0.08)))
                            .frame(width: 30, height: 30)
                        if done {
                            Image(systemName: "checkmark")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white)
                        } else {
                            Text("\(number)")
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(expanded ? Color.white : Color.secondary)
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.headline)
                            .foregroundStyle(done && !expanded ? Color.secondary : Color.primary)
                        Text(subtitle)
                            .font(.callout)
                            .foregroundStyle(done ? Color.green : Color.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(14)

            if expanded {
                content()
                    .padding(.leading, 58)
                    .padding([.trailing, .bottom], 16)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(expanded ? Color.accentColor.opacity(0.06) : Color.primary.opacity(0.035), in: learnCardShape)
        .overlay(learnCardShape.strokeBorder(expanded ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.06)))
    }
}

/// "Hold, speak, let go" for both keys, as a picture.
private struct HowItWorks: View {
    @Environment(Preferences.self) private var preferences

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How the keys work").font(.title2.weight(.semibold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 14, alignment: .top)], spacing: 14) {
                FlowCard(
                    color: Duck.dictation, title: "Dictation key",
                    stages: [
                        FlowStage(symbol: keyName(preferences.hotkey), caption: "Hold"),
                        FlowStage(symbol: "mic.fill", caption: "Speak"),
                        FlowStage(symbol: "hand.raised.fill", caption: "Let go"),
                        FlowStage(symbol: "text.cursor", caption: "Typed at the cursor"),
                    ]
                )
                FlowCard(
                    color: Duck.assistant, title: "AI key",
                    stages: [
                        FlowStage(symbol: keyName(preferences.assistantHotkey), caption: "Hold"),
                        FlowStage(symbol: "mic.fill", caption: "Ask or command"),
                        FlowStage(symbol: "hand.raised.fill", caption: "Let go"),
                        FlowStage(symbol: "sparkles", caption: "Answer or action"),
                    ]
                )
                FlowCard(
                    color: .red, title: "Meetings",
                    stages: [
                        FlowStage(symbol: "\(keyName(preferences.hotkey)) ×2", caption: "Double-tap"),
                        FlowStage(symbol: "person.2.wave.2.fill", caption: "Talk as usual"),
                        FlowStage(symbol: "stop.circle", caption: "Press again to stop"),
                        FlowStage(symbol: "checklist", caption: "Notes and to-dos"),
                    ]
                )
                FlowCard(
                    color: Duck.writing, title: "Writing tools",
                    stages: [
                        FlowStage(symbol: writingShortcut(for: "grammar"), caption: "Press in a text field"),
                        FlowStage(symbol: "doc.on.doc", caption: "Text copied"),
                        FlowStage(symbol: "wand.and.stars", caption: "AI rewrites"),
                        FlowStage(symbol: "text.cursor", caption: "Pasted back"),
                    ]
                )
            }
        }
    }
}

private struct FlowStage: Identifiable {
    /// SF Symbol name, or for the first stage the key's name (drawn as a keycap).
    let symbol: String
    let caption: String
    var id: String { caption }
}

private struct FlowCard: View {
    let color: Color
    let title: String
    let stages: [FlowStage]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline).foregroundStyle(color)
            HStack(alignment: .top, spacing: 4) {
                ForEach(stages) { stage in
                    let isFirst = stage.id == stages.first?.id
                    VStack(spacing: 6) {
                        if isFirst {
                            KeyCap(stage.symbol, compact: true).frame(height: 34)
                        } else {
                            Image(systemName: stage.symbol)
                                .font(.system(size: 18))
                                .foregroundStyle(color.gradient)
                                .frame(height: 34)
                        }
                        Text(stage.caption)
                            .font(.caption)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity)
                    if stage.id != stages.last?.id {
                        Image(systemName: "arrow.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.tertiary)
                            .frame(height: 34)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(color.opacity(0.07), in: learnCardShape)
        .overlay(learnCardShape.strokeBorder(color.opacity(0.2)))
    }
}

private struct ProgressRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.1), lineWidth: 7)
            Circle()
                .trim(from: 0, to: max(0.001, progress))
                .stroke(progress >= 1 ? Color.green : Color.accentColor, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.snappy, value: progress)
        }
    }
}

// MARK: - Commands

private struct CommandsTab: View {
    @Environment(Preferences.self) private var preferences
    @State private var filter: String?

    private var groups: [ToolGroup] {
        guard let filter else { return ToolCatalog.groups }
        return ToolCatalog.groups.filter { $0.id == filter }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Things you can say").font(.largeTitle.weight(.bold))
                HStack(spacing: 6) {
                    Text("Hold")
                    KeyCap(keyName(preferences.assistantHotkey), compact: true)
                    Text("and say any of these. Your own words work too.")
                }
                .font(.title3)
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 16) {
                LegendItem(symbol: "play.fill", color: .accentColor, text: "Click to try it now")
                LegendItem(symbol: "mic.fill", color: .secondary, text: "Say it with the AI key")
                LegendItem(symbol: "exclamationmark.shield", color: .orange, text: "Risky: can ask first (Settings)")
            }
            .font(.callout)

            if !preferences.macCommandsEnabled {
                HStack {
                    Label("Mac commands are off, so the AI key only answers questions.", systemImage: "exclamationmark.circle")
                    Spacer()
                    Button("Turn on") { preferences.macCommandsEnabled = true }
                        .buttonStyle(.borderedProminent)
                }
                .padding(12)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            ActiveTimersCard()

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    FilterChip(title: "All", symbol: "square.grid.2x2", selected: filter == nil) { filter = nil }
                    ForEach(ToolCatalog.groups) { group in
                        FilterChip(title: group.title, symbol: group.symbol, selected: filter == group.id) {
                            filter = (filter == group.id) ? nil : group.id
                        }
                    }
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 360), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
                ForEach(groups) { group in
                    CommandGroupCard(group: group)
                }
            }

            TipCard(
                symbol: "wand.and.stars",
                title: "No need for exact words",
                text: "“Could you fire up Xcode”, “x code kholo” or “make it louder” all work. Common phrasings run instantly; anything else is worked out by the AI model."
            )
        }
    }
}

private struct CommandGroupCard: View {
    @Environment(Preferences.self) private var preferences
    let group: ToolGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: group.symbol)
                    .font(.title3)
                    .foregroundStyle(Duck.orange.gradient)
                    .frame(width: 26)
                Text(group.title).font(.headline)
                Spacer()
                Text("\(group.examples.count)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.07), in: Capsule())
            }
            Text(group.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            FlowLayout(spacing: 6) {
                ForEach(group.examples) { example in
                    PhrasePill(example: example, canTry: preferences.macCommandsEnabled)
                }
            }

            if let note = group.note {
                Label(note, systemImage: "lightbulb")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.primary.opacity(0.035), in: learnCardShape)
        .overlay(learnCardShape.strokeBorder(Color.primary.opacity(0.07)))
    }
}

/// A phrase as a pill. Safe ones run when clicked; the rest are "say it" only.
struct PhrasePill: View {
    @Environment(AppState.self) private var appState
    let example: ToolExample
    let canTry: Bool
    @State private var hovering = false
    @State private var ran = false

    private var runnable: Bool { example.tryable && canTry }
    private var risky: Bool { CommandParser.parse(example.phrase)?.isRisky ?? false }

    var body: some View {
        if runnable {
            Button {
                appState.tryCommand(example.phrase)
                ran = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    ran = false
                }
            } label: {
                pill(icon: ran ? "checkmark" : "play.fill", tint: .accentColor)
            }
            .buttonStyle(.plain)
            .disabled(appState.isBusy)
            .help("Click to run “\(example.phrase)” now")
        } else {
            pill(icon: risky ? "exclamationmark.shield" : "mic.fill", tint: risky ? .orange : .secondary)
                .help(risky
                      ? "Say this with the AI key. It's a risky action, so it isn't run from here."
                      : "Say this with the AI key. It acts on the window you're using, so it isn't run from here.")
        }
    }

    private func pill(icon: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(tint)
            Text(example.phrase)
                .foregroundStyle(runnable ? Color.primary : Color.primary.opacity(0.85))
        }
        .font(.callout)
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(
            Capsule().fill(runnable ? Color.accentColor.opacity(hovering ? 0.2 : 0.09) : Color.primary.opacity(0.05))
        )
        .overlay(Capsule().strokeBorder(runnable && hovering ? Color.accentColor.opacity(0.5) : Color.clear))
        .contentShape(Capsule())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

private struct FilterChip: View {
    let title: String
    let symbol: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.callout.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(Capsule().fill(selected ? Color.accentColor : Color.primary.opacity(0.06)))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct LegendItem: View {
    let symbol: String
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold)).foregroundStyle(color)
            Text(text).foregroundStyle(.secondary)
        }
    }
}

/// Running voice timers with a live countdown and a cancel button.
struct ActiveTimersCard: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let timers = appState.timers.timers
        if !timers.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("Running now", systemImage: "timer")
                    .font(.headline)
                ForEach(timers) { timer in
                    HStack {
                        Image(systemName: timer.isReminder ? "bell" : "timer")
                            .foregroundStyle(.orange)
                        Text(timer.isReminder ? timer.label : "\(DurationText.spoken(timer.length ?? 0)) timer")
                        Spacer()
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(DurationText.clock(timer.fireDate.timeIntervalSince(context.date)))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Button {
                            appState.timers.cancel(timer.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Cancel")
                    }
                }
            }
            .padding(14)
            .background(Color.orange.opacity(0.08), in: learnCardShape)
            .overlay(learnCardShape.strokeBorder(Color.orange.opacity(0.2)))
        }
    }
}

// MARK: - Features

private struct LearnTopic: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let color: Color
    var isNew = false
    let summary: String
    let points: [String]
    /// A button to the screen where this is set up.
    var linkTitle: String? = nil
    var linkPage: SidebarItem? = nil
    /// For links to Settings: which page to open.
    var settingsTab: SettingsTab? = nil
}

private enum LearnContent {
    /// `writing` lists the writing tools' current shortcuts: "⌘G fixes grammar, ⌘E writes it as an email…".
    static func topics(dictate: String, ask: String, writing: String) -> [LearnTopic] {
        let dictation = LearnTopic(
            id: "dictation", title: "Dictation", symbol: "waveform", color: Duck.dictation,
            summary: "Type anywhere just by talking.",
            points: [
                "Click into any text field, in any app. Hold \(dictate), speak, then let go. Your words are typed at the cursor.",
                "While you talk, the popup shows what it hears. The final text replaces it when you let go.",
                "Press Esc while still holding the key to cancel.",
                "Filler words like “um” and “uh” are removed, and your clipboard is put back after pasting.",
                "If the text can't be typed (a password field, or a missing permission), it's left on the clipboard: press ⌘V.",
                "Pick your language in Settings › Dictation.",
            ],
            linkTitle: "Dictation settings", linkPage: .settings, settingsTab: .dictation)
        let assistant = LearnTopic(
            id: "assistant", title: "Ask the AI", symbol: "sparkles", color: Duck.assistant,
            summary: "A private AI that answers out loud.",
            points: [
                "Hold \(ask) and ask anything. Let go and a local AI model answers in the popup, and reads it aloud.",
                "Follow-up questions within 5 minutes continue the same conversation. Click New chat to start over.",
                "Press the key again while it's speaking: the voice stops so the mic hears only you.",
                "Choose Show and speak, Show only or Speak only, and pick a voice, in Settings › AI Assistant.",
                "The popup stays open while the pointer is over it. Copy the answer, hear it again, or close it with ×.",
            ],
            linkTitle: "AI settings", linkPage: .settings, settingsTab: .assistant)
        let commands = LearnTopic(
            id: "commands", title: "Mac commands", symbol: "command", color: .blue,
            summary: "Tell your Mac what to do with the same AI key.",
            points: [
                "Open apps, search the web, set timers, change the volume, take screenshots, lock the screen and more.",
                "Common commands run instantly, before the AI model even loads.",
                "Said it differently, or in another language? The AI model works out which command you mean.",
                "Risky actions run right away by default. Turn on “Ask before risky actions” to get Run and Cancel; you can also just say “yes”.",
                "Commands are saved in History with what they did.",
            ],
            linkTitle: "Mac command settings", linkPage: .settings, settingsTab: .assistant)
        let grammar = LearnTopic(
            id: "grammar", title: "Writing tools", symbol: "wand.and.stars", color: Duck.writing, isNew: true,
            summary: "Fix or rewrite the text in any field with one key.",
            points: [
                "Click into a text field and press a shortcut: \(writing).",
                "Duck Keyboard selects all the text, copies it, rewrites it with the local AI model and pastes the result back. The popup shows which action is running.",
                "Change any prompt or shortcut in Settings › Grammar, or add your own actions, like “Translate to Hindi” or “Make it shorter”.",
                "While an action is on, its shortcut belongs to Duck Keyboard, so the app's own command (⌘P Print, ⌘R Reload) won't run. Change it or turn the action off if you need it.",
                "Your clipboard is put back afterwards, and every rewrite is in History with the before and after.",
                "Works on up to 8,000 characters at a time. Nothing leaves your Mac.",
            ],
            linkTitle: "Writing tool settings", linkPage: .settings, settingsTab: .grammar)
        let timers = LearnTopic(
            id: "timers", title: "Timers & reminders", symbol: "timer", color: .pink,
            summary: "Countdowns, reminders and alarms by voice.",
            points: [
                "“Set a timer for 25 minutes”, “Remind me in an hour to stretch”, “Remind me at 5 pm to call mom”, “Set an alarm for 7 am”.",
                "When one goes off you hear a chime, get a notification, and the popup tells you.",
                "Ask “How much time is left?” or say “Cancel all timers”. Running ones are also in the menu bar.",
                "Quitting Duck Keyboard cancels its timers.",
            ])
        let models = LearnTopic(
            id: "models", title: "Settings & models", symbol: "slider.horizontal.3", color: .gray, isNew: true,
            summary: "One page per feature, with its models right there.",
            points: [
                "Settings has a page for each feature: Dictation, AI Assistant, Meetings, Grammar, General and Permissions.",
                "Models live on the page of the feature that uses them: the speech model in Dictation, the AI model in AI Assistant (and Grammar), the voice in AI Assistant.",
                "Click a model to use it. Download, delete, and choose where it runs (GPU, Neural Engine or MLX) on the same row.",
                "Add your own from Hugging Face, a folder or a .zip link with “Add custom model…”.",
                "Smaller models suit 8 GB Macs. General shows how much disk your models use.",
            ],
            linkTitle: "Open Settings", linkPage: .settings, settingsTab: .dictation)
        let history = LearnTopic(
            id: "history", title: "History", symbol: "clock.arrow.circlepath", color: Duck.orange, isNew: true,
            summary: "Everything you said, asked and rewrote, searchable.",
            points: [
                "Dictations, AI questions and rewrites are saved on this Mac, grouped by day, each with its own icon.",
                "Filter by Dictation, AI or Writing. Rewrites show the text before and after.",
                "Search by words, app or writing tool. Right-click to copy the original, the answer or the rewritten text, or to delete.",
                "Export as CSV or text from the toolbar. Choose how long to keep it in Settings › General.",
                "The menu bar shows your last five dictations: click one to copy it.",
            ],
            linkTitle: "Open History", linkPage: .history)
        let privacy = LearnTopic(
            id: "privacy", title: "Privacy", symbol: "lock.shield", color: .green,
            summary: "Nothing you say leaves this Mac.",
            points: [
                "Every model runs locally. Your voice, questions, meetings and rewritten text are never uploaded.",
                "The internet is only used to download models, and for websites and searches you ask to open.",
                "The microphone is only on while you hold a hotkey.",
            ])
        let background = LearnTopic(
            id: "background", title: "Always ready", symbol: "menubar.rectangle", color: .gray,
            summary: "Runs quietly in the menu bar.",
            points: [
                "Closing this window keeps Duck Keyboard running; the hotkeys keep working.",
                "The menu bar icon shows status, recent dictations and running timers.",
                "It can start at login (Settings › General).",
            ],
            linkTitle: "General settings", linkPage: .settings, settingsTab: .general)
        let meetings = LearnTopic(
            id: "meetings", title: "Meetings", symbol: "person.2.wave.2", color: .red, isNew: true,
            summary: "Record a meeting, get the transcript, a summary and to-dos.",
            points: [
                "Double-tap \(dictate) to start recording a meeting. A red “Meeting” capsule shows the time.",
                "Press \(dictate) once (or double-tap it) to stop. The local AI then writes a summary, key points, decisions and a to-do list.",
                "The other people on Zoom, Meet or Teams are recorded too, even with headphones on (allow Screen & System Audio Recording once).",
                "The transcript fills in while the meeting is going. When it ends, it's redone from your mic and the Mac's audio separately, with background noise and echo reduced.",
                "Lines are labelled “You”, “Speaker 1”, “Speaker 2”… Click a speaker in the Transcript tab to name them; the summary and to-dos update too.",
                "Open Meetings to read it, tick off to-dos, play the audio from any line, or export everything as Markdown.",
                "You can also start and stop a meeting from the menu bar or the Meetings screen. Turn the double-tap off in Settings › Meetings.",
            ],
            linkTitle: "Open Meetings", linkPage: .meetings)
        return [dictation, assistant, grammar, meetings, models, history, commands, timers, privacy, background]
    }
}

private struct FeaturesTab: View {
    @Environment(Preferences.self) private var preferences

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("What Duck Keyboard can do").font(.largeTitle.weight(.bold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 360), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
                ForEach(LearnContent.topics(dictate: keyName(preferences.hotkey), ask: keyName(preferences.assistantHotkey), writing: writingSummary(preferences.textActions))) { topic in
                    FeatureCard(topic: topic)
                }
            }
        }
    }
}

private struct FeatureCard: View {
    @Environment(AppState.self) private var appState
    let topic: LearnTopic
    @State private var showAll = false

    var body: some View {
        let visible = showAll ? topic.points : Array(topic.points.prefix(2))
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: topic.symbol)
                    .font(.title2)
                    .foregroundStyle(topic.color.gradient)
                    .frame(width: 40, height: 40)
                    .background(topic.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(topic.title).font(.headline)
                        if topic.isNew { NewBadge() }
                    }
                    Text(topic.summary).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(visible, id: \.self) { point in
                    BulletText(text: point, color: topic.color)
                }
            }
            HStack {
                if topic.points.count > 2 {
                    Button(showAll ? "Show less" : "Show \(topic.points.count - 2) more") {
                        withAnimation(.snappy) { showAll.toggle() }
                    }
                    .buttonStyle(.link)
                }
                Spacer()
                if let title = topic.linkTitle, let page = topic.linkPage {
                    Button(title) {
                        if let tab = topic.settingsTab { appState.settingsTab = tab }
                        appState.sidebarSelection = page
                    }
                        .controlSize(.small)
                }
            }
            .font(.callout)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.primary.opacity(0.035), in: learnCardShape)
        .overlay(learnCardShape.strokeBorder(Color.primary.opacity(0.07)))
    }
}

// MARK: - Tips & fixes

private enum FixAction {
    case microphone, accessibility, automation, notifications
    case settings(SettingsTab)
}

private struct HelpItem: Identifiable {
    let question: String
    let answer: String
    var fixTitle: String? = nil
    var fix: FixAction? = nil
    var id: String { question }

    static let all: [HelpItem] = [
        HelpItem(question: "⌘P doesn't print (or ⌘R doesn't reload) any more",
                 answer: "A writing tool is using that shortcut, and while it's on it works only for Duck Keyboard. Record a different shortcut for it, like ⌃⌥P, or turn that action off in Settings › Grammar.",
                 fixTitle: "Open Settings", fix: .settings(.grammar)),
        HelpItem(question: "A writing tool says “No text found”",
                 answer: "Click inside the text field first so the cursor is in it, then press the shortcut. Empty fields, password fields and apps with Secure Keyboard Entry can't be read. Accessibility must be allowed too.",
                 fixTitle: "Open Accessibility", fix: .accessibility),
        HelpItem(question: "The rewrite isn't what I wanted",
                 answer: "Each action follows its prompt. Make the prompt more specific in Settings › Grammar (for example “Keep it under 3 sentences” or “Use British spelling”), or pick a bigger AI model for writing tools in Settings › Models. Most apps let you undo a rewrite with ⌘Z.",
                 fixTitle: "Open Settings", fix: .settings(.grammar)),
        HelpItem(question: "My words don't appear in the app I'm typing in",
                 answer: "Check Accessibility above. macOS gives permissions to one specific copy of the app, so after rebuilding or moving it, remove Duck Keyboard in System Settings › Privacy & Security › Accessibility with –, then add this copy with +. In password fields, and in Terminal with Secure Keyboard Entry, typing is blocked: the text is on your clipboard, press ⌘V.",
                 fixTitle: "Open Accessibility", fix: .accessibility),
        HelpItem(question: "Nothing happens when I hold the key",
                 answer: "The hotkey only works with Accessibility allowed. Also check the key in Settings: if another app uses the same key, pick a different one. With Fn, set System Settings › Keyboard › “Press 🌐 key to” to “Do Nothing”.",
                 fixTitle: "Open Settings", fix: .settings(.dictation)),
        HelpItem(question: "It heard me wrong",
                 answer: "Speak a little closer to the mic, set your language in Settings › Dictation instead of auto-detect, or switch to a larger speech model in Settings › Models.",
                 fixTitle: "Open Settings", fix: .settings(.dictation)),
        HelpItem(question: "“Open …” opened the wrong app, or couldn't find it",
                 answer: "Say the app's name as it appears in your Applications folder (“Visual Studio Code”, “Google Chrome”). Common short names like “VS Code” and “Chrome” work too. If it isn't found, the popup suggests close matches."),
        HelpItem(question: "Dark mode or Empty Trash says macOS blocked it",
                 answer: "These control System Events and Finder. The first time, macOS asks: click OK. If you clicked Don't Allow, turn Duck Keyboard back on in System Settings › Privacy & Security › Automation.",
                 fixTitle: "Open Automation", fix: .automation),
        HelpItem(question: "I didn't get a notification when my timer finished",
                 answer: "Allow notifications for Duck Keyboard. You'll still hear the chime and see the popup either way.",
                 fixTitle: "Open Notifications", fix: .notifications),
        HelpItem(question: "My meeting only has my voice, not the other people",
                 answer: "Recording the Mac's audio needs Screen & System Audio Recording. Allow Duck Keyboard in System Settings › Privacy & Security › Screen & System Audio Recording, then quit and reopen Duck Keyboard. Check Settings › Meetings › Also record the Mac's audio is on.",
                 fixTitle: "Open Settings", fix: .settings(.meetings)),
        HelpItem(question: "The AI is slow the first time",
                 answer: "The model loads into memory once (a few seconds), then stays ready. On 8 GB Macs pick a smaller AI model in Settings › Models.",
                 fixTitle: "Open Settings", fix: .settings(.assistant)),
        HelpItem(question: "I don't want risky commands to run straight away",
                 answer: "Turn on Settings › AI Assistant › Ask before risky actions. Quitting apps, locking, sleeping, emptying the Trash and similar actions then wait for Run, or for you to say “yes”.",
                 fixTitle: "Open Settings", fix: .settings(.assistant)),
    ]
}

/// Carries out a Fix button.
@MainActor
private func perform(_ action: FixAction, appState: AppState) {
    switch action {
    case .microphone:
        Task {
            if !(await Permissions.requestMicrophone()) { Permissions.openMicrophoneSettings() }
        }
    case .accessibility:
        Permissions.requestAccessibility()
        Permissions.openAccessibilitySettings()
    case .automation:
        Shell.openAutomationSettings()
    case .notifications:
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    case .settings(let tab):
        appState.openSettings(tab)
    }
}

private struct HelpTab: View {
    @Environment(AppState.self) private var appState
    @State private var micGranted = Permissions.microphoneGranted
    @State private var axGranted = Permissions.accessibilityGranted
    @State private var keysGranted = Permissions.canSendKeystrokes
    @State private var notificationsGranted: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Tips & fixes").font(.largeTitle.weight(.bold))

            VStack(alignment: .leading, spacing: 10) {
                Text("Permissions").font(.headline)
                StatusRow(title: "Microphone", detail: "To hear you while you hold a hotkey", ok: micGranted, fixTitle: "Allow") {
                    perform(.microphone, appState: appState)
                }
                StatusRow(title: "Accessibility", detail: "For the hotkeys and typing into other apps", ok: axGranted, fixTitle: "Fix") {
                    perform(.accessibility, appState: appState)
                }
                StatusRow(title: "Send keystrokes", detail: "For pasting and window commands", ok: keysGranted, fixTitle: "Fix") {
                    Permissions.requestSendKeystrokes()
                    perform(.accessibility, appState: appState)
                }
                StatusRow(title: "Notifications", detail: notificationsGranted == nil ? "For timers. macOS asks the first time you set one" : "For timers and reminders",
                          ok: notificationsGranted ?? false, fixTitle: "Open", unknown: notificationsGranted == nil) {
                    perform(.notifications, appState: appState)
                }
                StatusRow(title: "Automation", detail: "For dark mode, Empty Trash and restart. macOS asks the first time",
                          ok: true, fixTitle: "Open", unknown: true) {
                    perform(.automation, appState: appState)
                }
            }
            .padding(16)
            .background(Color.primary.opacity(0.035), in: learnCardShape)

            VStack(alignment: .leading, spacing: 8) {
                Text("Common questions").font(.headline)
                ForEach(HelpItem.all) { item in
                    HelpRow(item: item)
                }
            }
        }
        .task {
            while !Task.isCancelled {
                micGranted = Permissions.microphoneGranted
                axGranted = Permissions.accessibilityGranted
                keysGranted = Permissions.canSendKeystrokes
                let settings = await UNUserNotificationCenter.current().notificationSettings()
                switch settings.authorizationStatus {
                case .authorized, .provisional: notificationsGranted = true
                case .denied: notificationsGranted = false
                default: notificationsGranted = nil   // not asked yet
                }
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }
}

private struct HelpRow: View {
    @Environment(AppState.self) private var appState
    let item: HelpItem
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy) { open.toggle() }
            } label: {
                HStack {
                    Image(systemName: "questionmark.circle.fill").foregroundStyle(Color.accentColor)
                    Text(item.question).font(.body.weight(.medium))
                    Spacer()
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(open ? 180 : 0))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if open {
                Text(item.answer)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.leading, 24)
                if let title = item.fixTitle, let fix = item.fix {
                    Button(title) { perform(fix, appState: appState) }
                        .padding(.leading, 24)
                }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Search

private struct LearnSearchResults: View {
    @Environment(Preferences.self) private var preferences
    let query: String

    private var phrases: [ToolExample] {
        ToolCatalog.groups.flatMap { group -> [ToolExample] in
            if group.title.localizedCaseInsensitiveContains(query) { return group.examples }
            return group.examples.filter { $0.phrase.localizedCaseInsensitiveContains(query) }
        }
    }

    private var topics: [LearnTopic] {
        LearnContent.topics(dictate: keyName(preferences.hotkey), ask: keyName(preferences.assistantHotkey), writing: writingSummary(preferences.textActions)).filter { topic in
            topic.title.localizedCaseInsensitiveContains(query)
                || topic.summary.localizedCaseInsensitiveContains(query)
                || topic.points.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private var help: [HelpItem] {
        HelpItem.all.filter { $0.question.localizedCaseInsensitiveContains(query) || $0.answer.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if phrases.isEmpty && topics.isEmpty && help.isEmpty {
                ContentUnavailableView.search(text: query)
            }
            if !phrases.isEmpty {
                ResultSection(title: "Things you can say", count: phrases.count) {
                    FlowLayout(spacing: 6) {
                        ForEach(phrases) { PhrasePill(example: $0, canTry: preferences.macCommandsEnabled) }
                    }
                }
            }
            if !topics.isEmpty {
                ResultSection(title: "Features", count: topics.count) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 360), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
                        ForEach(topics) { FeatureCard(topic: $0) }
                    }
                }
            }
            if !help.isEmpty {
                ResultSection(title: "Tips & fixes", count: help.count) {
                    VStack(spacing: 8) {
                        ForEach(help) { HelpRow(item: $0) }
                    }
                }
            }
        }
    }
}

private struct ResultSection<Content: View>: View {
    let title: String
    let count: Int
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(title).font(.title3.weight(.semibold))
                Text("\(count)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            content()
        }
    }
}

// MARK: - Shared pieces

private let learnCardShape = Duck.cardShape

/// A writing tool's current shortcut for a keycap ("⌘G"), or "no shortcut".
@MainActor
private func writingShortcut(for id: String) -> String {
    KeyboardShortcuts.getShortcut(for: TextActionCatalog.shortcutName(for: id))?.description ?? "no shortcut"
}

/// "⌘G: Fix grammar and typos, ⌘E: Write as email, …" for the enabled writing tools that have a shortcut.
@MainActor
private func writingSummary(_ actions: [TextAction]) -> String {
    let parts = actions.filter(\.enabled).compactMap { action -> String? in
        guard let shortcut = KeyboardShortcuts.getShortcut(for: action.shortcutName) else { return nil }
        return "\(shortcut.description) \(action.title.lowercased())"
    }
    return parts.isEmpty ? "set one up in Settings › Grammar" : parts.joined(separator: ", ")
}

/// Short name for the keycap ("Right ⌥"); custom shortcuts read "your shortcut".
private func keyName(_ choice: HotkeyChoice) -> String {
    switch choice {
    case .rightOption: return "Right ⌥"
    case .rightCommand: return "Right ⌘"
    case .rightControl: return "Right ⌃"
    case .fn: return "Fn 🌐"
    case .custom: return "your shortcut"
    case .off: return "(off)"
    }
}

/// A key drawn like the keys in the app icon.
private struct KeyCap: View {
    let name: String
    var compact = false

    init(_ name: String, compact: Bool = false) {
        self.name = name
        self.compact = compact
    }

    var body: some View {
        DuckKeycap(name, size: compact ? .regular : .large)
    }
}

private struct InstructionLine: View {
    let key: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            KeyCap(key, compact: true)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct StatusRow: View {
    let title: String
    let detail: String
    let ok: Bool
    let fixTitle: String
    var unknown = false
    let fix: () -> Void

    init(title: String, detail: String, ok: Bool, fixTitle: String, unknown: Bool = false, fix: @escaping () -> Void) {
        self.title = title
        self.detail = detail
        self.ok = ok
        self.fixTitle = fixTitle
        self.unknown = unknown
        self.fix = fix
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: unknown ? "circle.dashed" : (ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill"))
                .font(.title3)
                .foregroundStyle(unknown ? Color.secondary : (ok ? Color.green : Color.orange))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !ok || unknown {
                Button(fixTitle, action: fix)
            }
        }
    }
}

private struct BulletText: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(color.opacity(0.7))
                .frame(width: 5, height: 5)
                .padding(.top, 7)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}

private struct TipCard: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(Duck.orange.gradient)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Duck.orange.opacity(0.07), in: learnCardShape)
    }
}

private struct NewBadge: View {
    var body: some View {
        Text("NEW")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Duck.orange.gradient, in: Capsule())
    }
}

/// Lays children out left to right, wrapping onto new lines (for phrase pills).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
