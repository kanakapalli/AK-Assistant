import SwiftUI

/// Settings › Models: which model each feature uses, plus every model the app can run —
/// download, delete, where it runs (GPU, Neural Engine, CPU, MLX) and custom models.
struct ModelsSettings: View {
    @Environment(Preferences.self) private var preferences
    @Environment(ModelManager.self) private var modelManager
    @Environment(AppState.self) private var appState

    @State private var filter: LibraryFilter = .all
    @State private var downloadedOnly = false
    @State private var adding: AddRequest?
    @State private var pendingDelete: PendingDelete?
    @State private var highlighted: ModelFeature?

    enum LibraryFilter: String, CaseIterable, Identifiable {
        case all, speech, chat, voice, search

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "All"
            case .speech: return "Speech"
            case .chat: return "AI"
            case .voice: return "Voice"
            case .search: return "Search"
            }
        }

        var kinds: [ModelKind] {
            switch self {
            case .all: return ModelKind.allCases
            case .speech: return [.speech]
            case .chat: return [.chat]
            case .voice: return [.voice]
            case .search: return [.search]
            }
        }
    }

    private struct AddRequest: Identifiable {
        let kind: CustomModelRecord.Kind
        var id: String { kind.rawValue }
    }

    /// Something the user asked to delete, waiting for confirmation.
    private struct PendingDelete: Identifiable {
        let id = UUID()
        let name: String
        let isCustom: Bool
        let usedBy: [ModelFeature]
        let perform: () -> Void
    }

    private var lookup: ModelLookup {
        ModelLookup(modelManager: modelManager, preferences: preferences, memory: appState.memory)
    }

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                Section {
                    ModelsOverview()
                }

                Section {
                    ForEach(ModelFeature.allCases) { feature in
                        FeatureAssignmentRow(feature: feature, highlighted: highlighted == feature)
                            .id(feature)
                    }
                } header: {
                    Text("Features")
                } footer: {
                    SettingCaption("Pick the model each feature uses. “Same as …” follows another feature, so changing that one changes both. Dimmed features are switched off on their own Settings page.")
                }

                Section {
                    Picker("Show", selection: $filter) {
                        ForEach(LibraryFilter.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Only downloaded models", isOn: $downloadedOnly)
                } header: {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Model library")
                        Spacer()
                        Menu {
                            Button {
                                adding = AddRequest(kind: .speech)
                            } label: {
                                Label("Speech-to-text model…", systemImage: ModelKind.speech.symbol)
                            }
                            Button {
                                adding = AddRequest(kind: .chat)
                            } label: {
                                Label("AI model…", systemImage: ModelKind.chat.symbol)
                            }
                        } label: {
                            Label("Add custom model", systemImage: "plus")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .controlSize(.small)
                        .help("Add a model from Hugging Face, a download link, or a folder on this Mac")
                    }
                }

                ForEach(filter.kinds) { kind in
                    librarySection(kind)
                }
            }
            .formStyle(.grouped)
            .onAppear { focusIfAsked(proxy) }
        }
        .sheet(item: $adding) { request in
            AddCustomModelSheet(kind: request.kind)
        }
        .confirmationDialog(
            "Delete \(pendingDelete?.name ?? "model")?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { item in
            Button("Delete", role: .destructive) { item.perform() }
        } message: { item in
            Text(deleteMessage(item))
        }
    }

    // MARK: Library

    @ViewBuilder private func librarySection(_ kind: ModelKind) -> some View {
        let items = lookup.entries(kind).filter { !downloadedOnly || $0.state == .downloaded }
        Section {
            if items.isEmpty {
                Text("No downloaded \(kind.title.lowercased()) models yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(items) { entry in
                LibraryRow(
                    entry: entry,
                    usedBy: preferences.features(using: entry.id, kind: kind),
                    assignable: kind == .search ? [] : ModelFeature.allCases.filter { $0.kind == kind },
                    onAssign: { preferences.assign(entry.id, to: $0) },
                    onDelete: {
                        pendingDelete = PendingDelete(
                            name: entry.name,
                            isCustom: entry.isCustom,
                            usedBy: preferences.features(using: entry.id, kind: kind),
                            perform: entry.delete
                        )
                    }
                )
            }
        } header: {
            Label(kind.title, systemImage: kind.symbol)
        } footer: {
            SettingCaption(kind.libraryCaption)
        }
    }

    private func deleteMessage(_ item: PendingDelete) -> String {
        if item.isCustom {
            return "Custom models are removed completely. Features using it go back to their default model."
        }
        if item.usedBy.isEmpty {
            return "Its files are removed from this Mac. You can download it again any time."
        }
        let names = item.usedBy.map(\.shortTitle).joined(separator: ", ")
        return "Used by \(names). They won't work until it's downloaded again or you pick another model."
    }

    /// Opened from a "Change…" link on another Settings page: scroll to that feature and flash it.
    private func focusIfAsked(_ proxy: ScrollViewProxy) {
        guard let feature = appState.modelsFocus else { return }
        appState.modelsFocus = nil
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            withAnimation { proxy.scrollTo(feature, anchor: .center) }
            withAnimation(.easeOut(duration: 0.2)) { highlighted = feature }
            try? await Task.sleep(for: .seconds(1.8))
            withAnimation(.easeIn(duration: 0.4)) { highlighted = nil }
        }
    }
}

// MARK: - Overview

/// Three tiles at the top: features ready, models downloaded, disk used.
private struct ModelsOverview: View {
    @Environment(Preferences.self) private var preferences
    @Environment(ModelManager.self) private var modelManager
    @Environment(AppState.self) private var appState
    @State private var diskUsage = "…"

    var body: some View {
        let lookup = ModelLookup(modelManager: modelManager, preferences: preferences, memory: appState.memory)
        let active = ModelFeature.allCases.filter { preferences.isActive($0) }
        let ready = active.filter { lookup.state(preferences.effectiveModelID(for: $0), $0.kind) == .downloaded }
        let downloaded = ModelKind.allCases.reduce(0) { total, kind in
            total + lookup.entries(kind).filter { $0.state == .downloaded }.count
        }
        let allReady = ready.count == active.count

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                StatTile(symbol: allReady ? "checkmark.seal.fill" : "exclamationmark.triangle.fill",
                         tint: allReady ? .green : .orange,
                         value: "\(ready.count) of \(active.count)",
                         label: "Features ready")
                StatTile(symbol: "arrow.down.circle.fill", tint: .blue,
                         value: "\(downloaded)", label: "Models downloaded")
                StatTile(symbol: "internaldrive.fill", tint: .gray,
                         value: diskUsage, label: "Disk used")
            }
            if !allReady {
                Text("Some features that are switched on still need their model. Click Download next to them below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        // Measuring folders is slow; only redo it when a download finishes or a model is deleted.
        .task(id: downloaded) { diskUsage = modelManager.diskUsageLabel }
    }
}

private struct StatTile: View {
    let symbol: String
    let tint: Color
    let value: String
    let label: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.secondary.opacity(0.08)))
    }
}

// MARK: - Feature rows

/// One feature: what it does, whether its model is ready, and a menu to pick the model.
private struct FeatureAssignmentRow: View {
    let feature: ModelFeature
    var highlighted = false

    @Environment(Preferences.self) private var preferences
    @Environment(ModelManager.self) private var modelManager
    @Environment(AppState.self) private var appState

    var body: some View {
        let lookup = ModelLookup(modelManager: modelManager, preferences: preferences, memory: appState.memory)
        let active = preferences.isActive(feature)
        let effectiveID = preferences.effectiveModelID(for: feature)
        let state = lookup.state(effectiveID, feature.kind)

        HStack(alignment: .center, spacing: 12) {
            ModelKindIcon(symbol: feature.symbol, kind: feature.kind, dimmed: !active)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(feature.title)
                    if !active {
                        Pill(text: "Off", tint: .secondary)
                            .help("Switched off in Settings › \(feature.settingsTab.title)")
                    }
                }
                Text(feature.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .opacity(active ? 1 : 0.6)
            .layoutPriority(1)

            Spacer(minLength: 12)

            StateControl(state: state, compact: true) {
                lookup.download(effectiveID, feature.kind)
            }

            picker(lookup)
                .frame(minWidth: 170, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.accentColor.opacity(highlighted ? 0.16 : 0))
                .padding(-6)
        }
    }

    @ViewBuilder private func picker(_ lookup: ModelLookup) -> some View {
        if feature.kind == .search {
            Label(GemmaEmbedder.displayName, systemImage: "lock.fill")
                .font(.callout)
                .foregroundStyle(.secondary)
                .help("Smart search uses one built-in model.")
        } else {
            let options = lookup.options(feature.kind)
            let assigned = preferences.assignedModelID(for: feature)
            Picker(feature.title, selection: Binding(
                get: { preferences.assignedModelID(for: feature) },
                set: { preferences.assign($0, to: feature) }
            )) {
                if let parent = feature.follows {
                    let parentID = preferences.effectiveModelID(for: parent)
                    Text("Same as \(parent.shortTitle) (\(lookup.name(parentID, feature.kind)))").tag("")
                    Divider()
                }
                ForEach(options) { option in
                    Text(option.ready ? option.name : "\(option.name) · not downloaded").tag(option.id)
                }
                // A picked model that was since removed keeps a matching tag.
                if !assigned.isEmpty, !options.contains(where: { $0.id == assigned }) {
                    Text("Missing model").tag(assigned)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 260)
        }
    }
}

// MARK: - Library rows

private struct LibraryRow: View {
    let entry: ModelLookup.Entry
    let usedBy: [ModelFeature]
    let assignable: [ModelFeature]
    let onAssign: (ModelFeature) -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ModelKindIcon(symbol: entry.kind.symbol, kind: entry.kind, dimmed: entry.state != .downloaded)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(entry.name).font(.headline)
                    if entry.recommended { Pill(text: "Recommended", tint: .accentColor) }
                    if entry.isCustom { Pill(text: "Custom", tint: .purple) }
                }
                Text(entry.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // Wraps onto a second line instead of squeezing each fact into a one-letter column.
                FlowLayout(spacing: 12) {
                    ForEach(entry.facts) { fact in
                        Label(fact.text, systemImage: fact.symbol)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                usedByRow
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            VStack(alignment: .trailing, spacing: 8) {
                StateControl(state: entry.state, compact: false, onDownload: entry.download, onDelete: onDelete)
                runtimeControl
                if !assignable.isEmpty { useForMenu }
            }
            .fixedSize()
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var usedByRow: some View {
        if usedBy.isEmpty {
            Text("Not used by any feature")
                .font(.caption)
                .foregroundStyle(.tertiary)
        } else {
            HStack(alignment: .center, spacing: 6) {
                Text("Used by")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                FlowLayout(spacing: 6) {
                    ForEach(usedBy) { feature in
                        Label(feature.shortTitle, systemImage: feature.symbol)
                            .font(.caption2.weight(.medium))
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(entry.kind.tint.opacity(0.14), in: Capsule())
                            .foregroundStyle(entry.kind.tint)
                    }
                }
            }
        }
    }

    @ViewBuilder private var runtimeControl: some View {
        if entry.runtimes.count > 1, let setRuntime = entry.setRuntime {
            // Inside a Form a labelled Picker gets its own label column, which pushed "Runs on" into
            // the middle of the row and the controls off the right edge. Hide it and draw it here.
            HStack(spacing: 6) {
                Text("Runs on")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Runs on", selection: Binding(get: { entry.runtime }, set: setRuntime)) {
                    ForEach(entry.runtimes) { runtime in
                        Label(runtime.shortTitle, systemImage: runtime.symbol).tag(runtime)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
            }
            .help(entry.runtime.detail + (entry.runtimes.contains(.mlx) ? " Switching to or from MLX needs its own download." : ""))
        } else {
            Label("Runs on \(entry.runtime.shortTitle)", systemImage: entry.runtime.symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(entry.runtime.detail)
        }
    }

    private var useForMenu: some View {
        Menu {
            ForEach(assignable) { feature in
                Button {
                    onAssign(feature)
                } label: {
                    if usedBy.contains(feature) {
                        Label(feature.title, systemImage: "checkmark")
                    } else {
                        Text(feature.title)
                    }
                }
            }
        } label: {
            Text("Use for")
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .fixedSize()
        .help("Assign this model to a feature")
    }
}

// MARK: - Small pieces

/// Download button, progress, Ready + delete, or Retry.
private struct StateControl: View {
    let state: ModelManager.State
    /// Feature rows: just an icon when ready, and no delete.
    var compact: Bool
    var onDownload: () -> Void
    var onDelete: (() -> Void)? = nil

    var body: some View {
        switch state {
        case .notDownloaded:
            Button(compact ? "Download" : "Download", action: onDownload)
                .controlSize(compact ? .small : .regular)
        case .downloading(let progress):
            HStack(spacing: 6) {
                if let progress {
                    ProgressView(value: progress).frame(width: compact ? 60 : 100)
                    Text("\(Int(progress * 100))%").font(.caption).monospacedDigit()
                } else {
                    ProgressView().controlSize(.small)
                    Text("Downloading…").font(.caption)
                }
            }
        case .downloaded:
            if compact {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .help("Downloaded and ready")
            } else {
                HStack(spacing: 8) {
                    Label("Ready", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout)
                    if let onDelete {
                        Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help("Delete model")
                    }
                }
            }
        case .failed(let message):
            VStack(alignment: .trailing, spacing: 2) {
                Button("Retry", action: onDownload)
                    .controlSize(compact ? .small : .regular)
                if !compact {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .frame(maxWidth: 180, alignment: .trailing)
                }
            }
            .help(message)
        }
    }
}

/// A coloured rounded square with a symbol, like System Settings.
private struct ModelKindIcon: View {
    let symbol: String
    let kind: ModelKind
    var dimmed = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(kind.tint.gradient))
            .opacity(dimmed ? 0.45 : 1)
    }
}

private struct Pill: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.15), in: Capsule())
    }
}

extension ModelKind {
    var tint: Color {
        switch self {
        case .speech: return Duck.dictation
        case .chat: return Duck.assistant
        case .voice: return .pink
        case .search: return .teal
        }
    }
}

// MARK: - Model link on each feature's page

/// Names the model(s) a feature uses on its own Settings page, with a link to Settings › Models.
struct ModelLinkSection: View {
    let features: [ModelFeature]

    var body: some View {
        Section {
            ForEach(features) { ModelLinkRow(feature: $0) }
        } header: {
            Text(features.count == 1 ? "Model" : "Models")
        } footer: {
            SettingCaption("Pick, download and choose where models run in Settings › Models.")
        }
    }
}

/// "Speech model    Parakeet Ultra   [Change…]"
struct ModelLinkRow: View {
    let feature: ModelFeature

    @Environment(Preferences.self) private var preferences
    @Environment(ModelManager.self) private var modelManager
    @Environment(AppState.self) private var appState

    var body: some View {
        let lookup = ModelLookup(modelManager: modelManager, preferences: preferences, memory: appState.memory)
        let id = preferences.effectiveModelID(for: feature)
        let follows = preferences.assignedModelID(for: feature).isEmpty ? feature.follows : nil

        LabeledContent {
            HStack(spacing: 8) {
                switch lookup.state(id, feature.kind) {
                case .downloaded:
                    EmptyView()
                case .downloading:
                    ProgressView().controlSize(.small)
                case .notDownloaded, .failed:
                    Label("Not downloaded", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text(lookup.name(id, feature.kind) + (follows.map { " (same as \($0.shortTitle))" } ?? ""))
                    .foregroundStyle(.secondary)
                Button("Change…") {
                    appState.modelsFocus = feature
                    appState.settingsTab = .models
                }
            }
        } label: {
            Label(feature.kind == .speech && feature != .dictation ? "Speech model for the clean-up"
                  : feature == .meetingNotes ? "AI model for notes"
                  : feature == .writingTools ? "AI model for writing tools"
                  : feature.kind.modelTitle,
                  systemImage: feature.kind.symbol)
        }
    }
}

// MARK: - Looking models up by kind and id

/// One place that knows how to find, describe, download and delete each kind of model.
@MainActor
struct ModelLookup {
    let modelManager: ModelManager
    let preferences: Preferences
    let memory: MemoryCenter

    struct Fact: Identifiable, Hashable {
        let symbol: String
        let text: String
        var id: String { symbol + text }
    }

    struct Option: Identifiable {
        let id: String
        let name: String
        let ready: Bool
    }

    /// A model in the library, whatever its kind.
    struct Entry: Identifiable {
        let id: String
        let kind: ModelKind
        let name: String
        let summary: String
        let facts: [Fact]
        let recommended: Bool
        let isCustom: Bool
        let state: ModelManager.State
        let runtimes: [ModelRuntime]
        let runtime: ModelRuntime
        let setRuntime: ((ModelRuntime) -> Void)?
        let download: () -> Void
        let delete: () -> Void
    }

    func name(_ id: String, _ kind: ModelKind) -> String {
        switch kind {
        case .speech: return ModelCatalog.model(id: id)?.name ?? "Missing model"
        case .chat: return AssistantCatalog.chatModel(id: id)?.name ?? "Missing model"
        case .voice: return AssistantCatalog.voiceModel(id: id)?.name ?? "Missing model"
        case .search: return GemmaEmbedder.displayName
        }
    }

    func state(_ id: String, _ kind: ModelKind) -> ModelManager.State {
        switch kind {
        case .speech:
            guard let model = ModelCatalog.model(id: id) else { return .notDownloaded }
            return modelManager.state(of: model)
        case .chat:
            guard let model = AssistantCatalog.chatModel(id: id) else { return .notDownloaded }
            return modelManager.state(of: model)
        case .voice:
            guard let voice = AssistantCatalog.voiceModel(id: id) else { return .notDownloaded }
            return modelManager.state(of: voice)
        case .search:
            return Self.state(of: memory.embedding.state)
        }
    }

    func download(_ id: String, _ kind: ModelKind) {
        let manager = modelManager
        switch kind {
        case .speech:
            if let model = ModelCatalog.model(id: id) { Task { await manager.download(model) } }
        case .chat:
            if let model = AssistantCatalog.chatModel(id: id) { Task { await manager.download(model) } }
        case .voice:
            if let voice = AssistantCatalog.voiceModel(id: id) { Task { await manager.download(voice) } }
        case .search:
            preferences.memoryEnabled = true
            let center = memory
            Task { await center.enable() }
        }
    }

    /// Models of one kind for a feature's menu.
    func options(_ kind: ModelKind) -> [Option] {
        switch kind {
        case .speech: return ModelCatalog.all.map { Option(id: $0.id, name: $0.name, ready: modelManager.isDownloaded($0)) }
        case .chat: return AssistantCatalog.chatModels.map { Option(id: $0.id, name: $0.name, ready: modelManager.isDownloaded($0)) }
        case .voice: return AssistantCatalog.voiceModels.map { Option(id: $0.id, name: $0.name, ready: modelManager.isDownloaded($0)) }
        case .search: return []
        }
    }

    /// Every model of one kind, for the library.
    func entries(_ kind: ModelKind) -> [Entry] {
        let manager = modelManager
        let prefs = preferences
        switch kind {
        case .speech:
            return ModelCatalog.all.map { model in
                let runtime = ModelRuntimeStore.shared.runtime(for: model)
                // MLX uses its own download, so show its size when MLX is picked.
                let size = runtime == .mlx ? (model.mlx?.sizeLabel ?? model.sizeLabel) : model.sizeLabel
                return Entry(
                    id: model.id, kind: .speech, name: model.name, summary: model.summary,
                    facts: model.isCustom
                        ? [Fact(symbol: "internaldrive", text: size)]
                        : [
                            Fact(symbol: "internaldrive", text: size),
                            Fact(symbol: "globe", text: model.languages),
                            Fact(symbol: "hare", text: "Speed \(Self.dots(model.speed))"),
                            Fact(symbol: "target", text: "Accuracy \(Self.dots(model.accuracy))"),
                        ],
                    recommended: model.id == ModelCatalog.defaultModel.id,
                    isCustom: model.isCustom,
                    state: manager.state(of: model),
                    runtimes: model.availableRuntimes,
                    runtime: runtime,
                    setRuntime: { ModelRuntimeStore.shared.set($0, for: model) },
                    download: { Task { await manager.download(model) } },
                    delete: {
                        if model.isCustom {
                            manager.removeCustom(model.id)
                            prefs.unassign(model.id)
                        } else {
                            manager.delete(model)
                        }
                    }
                )
            }
        case .chat:
            return AssistantCatalog.chatModels.map { model in
                Entry(
                    id: model.id, kind: .chat, name: model.name, summary: model.summary,
                    facts: model.isCustom
                        ? [Fact(symbol: "internaldrive", text: model.sizeLabel)]
                        : [
                            Fact(symbol: "internaldrive", text: model.sizeLabel),
                            Fact(symbol: "hare", text: "Speed \(Self.dots(model.speed))"),
                            Fact(symbol: "brain", text: "Quality \(Self.dots(model.quality))"),
                        ],
                    recommended: model.id == AssistantCatalog.defaultChatModel.id,
                    isCustom: model.isCustom,
                    state: manager.state(of: model),
                    runtimes: [.mlx],
                    runtime: .mlx,
                    setRuntime: nil,
                    download: { Task { await manager.download(model) } },
                    delete: {
                        if model.isCustom {
                            manager.removeCustom(model.id)
                            prefs.unassign(model.id)
                        } else {
                            manager.delete(model)
                        }
                    }
                )
            }
        case .voice:
            return AssistantCatalog.voiceModels.map { voice in
                Entry(
                    id: voice.id, kind: .voice, name: voice.name, summary: voice.summary,
                    facts: [
                        Fact(symbol: "internaldrive", text: voice.sizeLabel),
                        Fact(symbol: "globe", text: "10 languages"),
                    ],
                    recommended: voice.id == AssistantCatalog.defaultVoiceModel.id,
                    isCustom: false,
                    state: manager.state(of: voice),
                    runtimes: VoiceModel.runtimes,
                    runtime: ModelRuntimeStore.shared.runtime(for: voice),
                    setRuntime: { ModelRuntimeStore.shared.set($0, for: voice) },
                    download: { Task { await manager.download(voice) } },
                    delete: { manager.delete(voice) }
                )
            }
        case .search:
            let center = memory
            return [
                Entry(
                    id: GemmaEmbedder.repo, kind: .search, name: GemmaEmbedder.displayName,
                    summary: "Google's on-device embedding model: understands meaning in 100+ languages. Downloaded when Smart search & memory is turned on.",
                    facts: [
                        Fact(symbol: "internaldrive", text: GemmaEmbedder.sizeLabel),
                        Fact(symbol: "globe", text: "100+ languages"),
                    ],
                    recommended: false,
                    isCustom: false,
                    state: Self.state(of: center.embedding.state),
                    runtimes: [.mlx],
                    runtime: .mlx,
                    setRuntime: nil,
                    download: {
                        prefs.memoryEnabled = true
                        Task { await center.enable() }
                    },
                    delete: {
                        // The index is built with this model, so both go together.
                        center.deleteAll()
                        prefs.memoryEnabled = false
                    }
                ),
            ]
        }
    }

    static func state(of embedding: EmbeddingService.State) -> ModelManager.State {
        switch embedding {
        case .notDownloaded: return .notDownloaded
        case .downloading(let fraction): return .downloading(progress: fraction)
        case .notLoaded, .loading, .ready: return .downloaded
        case .failed(let message): return .failed(message)
        }
    }

    private static func dots(_ n: Int) -> String {
        String(repeating: "●", count: n) + String(repeating: "○", count: max(0, 5 - n))
    }
}
