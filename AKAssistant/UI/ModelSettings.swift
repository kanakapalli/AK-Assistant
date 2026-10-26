import SwiftUI

/// Pick, download, delete and add models, inside the Settings page of the feature that uses them:
/// speech in Dictation, the AI model in AI Assistant and Grammar, the voice in AI Assistant.
struct ModelChoiceSection: View {
    enum Kind {
        case speech, chat, voice

        var title: String {
            switch self {
            case .speech: return "Speech model"
            case .chat: return "AI model"
            case .voice: return "Voice model"
            }
        }

        /// Which "Add custom model" sheet this list offers (voices can't be added).
        var customKind: CustomModelRecord.Kind? {
            switch self {
            case .speech: return .speech
            case .chat: return .chat
            case .voice: return nil
            }
        }
    }

    let kind: Kind
    /// Shown under the list: what the model is used for.
    var caption: String? = nil

    @Environment(Preferences.self) private var preferences
    @Environment(ModelManager.self) private var modelManager
    @State private var pendingDelete: PendingDelete?
    @State private var addingCustom = false

    /// Something the user asked to delete, waiting for confirmation.
    private struct PendingDelete: Identifiable {
        let id = UUID()
        let name: String
        let perform: () -> Void
    }

    var body: some View {
        Section {
            rows
        } header: {
            HStack(alignment: .firstTextBaseline) {
                Text(kind.title)
                Spacer()
                if kind.customKind != nil {
                    Button {
                        addingCustom = true
                    } label: {
                        Label("Add custom model…", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Add a model from Hugging Face, a download link, or a folder on this Mac")
                }
            }
        } footer: {
            if let caption {
                SettingCaption(caption)
            }
        }
        .sheet(isPresented: $addingCustom) {
            if let custom = kind.customKind {
                AddCustomModelSheet(kind: custom)
            }
        }
        .confirmationDialog(
            "Delete \(pendingDelete?.name ?? "model")?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { item in
            Button("Delete", role: .destructive) { item.perform() }
        }
    }

    @ViewBuilder private var rows: some View {
        switch kind {
        case .speech:
            ForEach(ModelCatalog.all) { model in
                ModelCard(model: model, selected: preferences.selectedModelID == model.id, plain: true) {
                    preferences.selectedModelID = model.id
                } onDelete: {
                    pendingDelete = PendingDelete(name: model.name) {
                        if model.isCustom {
                            // Custom models disappear completely; fall back to the default if it was in use.
                            modelManager.removeCustom(model.id)
                            if preferences.selectedModelID == model.id { preferences.selectedModelID = ModelCatalog.defaultModel.id }
                        } else {
                            modelManager.delete(model)
                        }
                    }
                }
            }
        case .chat:
            ForEach(AssistantCatalog.chatModels) { model in
                ChatModelCard(model: model, selected: preferences.chatModelID == model.id, plain: true) {
                    preferences.chatModelID = model.id
                } onDelete: {
                    pendingDelete = PendingDelete(name: model.name) {
                        if model.isCustom {
                            modelManager.removeCustom(model.id)
                            if preferences.chatModelID == model.id { preferences.chatModelID = AssistantCatalog.defaultChatModel.id }
                        } else {
                            modelManager.delete(model)
                        }
                    }
                }
            }
        case .voice:
            ForEach(AssistantCatalog.voiceModels) { voice in
                VoiceModelCard(voice: voice, selected: preferences.voiceModelID == voice.id, plain: true) {
                    preferences.voiceModelID = voice.id
                } onDelete: {
                    pendingDelete = PendingDelete(name: voice.name) { modelManager.delete(voice) }
                }
            }
        }
    }
}

// MARK: - Cards for each kind of model

/// A speech-to-text model card.
struct ModelCard: View {
    @Environment(ModelManager.self) private var modelManager

    let model: SpeechModel
    let selected: Bool
    /// A row inside a Settings form instead of a stand-alone card.
    var plain = false
    var onSelect: () -> Void
    var onDelete: (() -> Void)? = nil

    private var runtimeStore: ModelRuntimeStore { .shared }

    var body: some View {
        let runtime = runtimeStore.runtime(for: model)
        // MLX uses its own download, so show its size when MLX is picked.
        let size = runtime == .mlx ? (model.mlx?.sizeLabel ?? model.sizeLabel) : model.sizeLabel
        ModelTile(
            name: model.name,
            recommended: model.id == ModelCatalog.defaultModel.id,
            summary: model.summary,
            facts: model.isCustom
                ? [("internaldrive", size), ("shippingbox", "Custom")]
                : [
                    ("internaldrive", size),
                    ("globe", model.languages),
                    ("hare", "Speed \(dots(model.speed))"),
                    ("target", "Accuracy \(dots(model.accuracy))"),
                ],
            state: modelManager.state(of: model),
            selected: selected,
            onSelect: onSelect,
            onDownload: { Task { await modelManager.download(model) } },
            onDelete: onDelete,
            runtimes: model.availableRuntimes,
            runtime: runtime,
            onRuntime: { runtimeStore.set($0, for: model) },
            plain: plain
        )
    }
}

/// An AI chat model card.
struct ChatModelCard: View {
    @Environment(ModelManager.self) private var modelManager

    let model: ChatModel
    let selected: Bool
    var plain = false
    var onSelect: () -> Void
    var onDelete: (() -> Void)? = nil

    var body: some View {
        ModelTile(
            name: model.name,
            recommended: model.id == AssistantCatalog.defaultChatModel.id,
            summary: model.summary,
            facts: model.isCustom
                ? [("internaldrive", model.sizeLabel), ("shippingbox", "Custom")]
                : [
                    ("internaldrive", model.sizeLabel),
                    ("hare", "Speed \(dots(model.speed))"),
                    ("brain", "Quality \(dots(model.quality))"),
                ],
            state: modelManager.state(of: model),
            selected: selected,
            onSelect: onSelect,
            onDownload: { Task { await modelManager.download(model) } },
            onDelete: onDelete,
            runtimes: [.mlx],
            runtime: .mlx,
            plain: plain
        )
    }
}

/// A text-to-speech voice model card.
struct VoiceModelCard: View {
    @Environment(ModelManager.self) private var modelManager

    let voice: VoiceModel
    let selected: Bool
    var plain = false
    var onSelect: () -> Void
    var onDelete: (() -> Void)? = nil

    var body: some View {
        ModelTile(
            name: voice.name,
            recommended: voice.id == AssistantCatalog.defaultVoiceModel.id,
            summary: voice.summary,
            facts: [
                ("internaldrive", voice.sizeLabel),
                ("globe", "10 languages"),
            ],
            state: modelManager.state(of: voice),
            selected: selected,
            onSelect: onSelect,
            onDownload: { Task { await modelManager.download(voice) } },
            onDelete: onDelete,
            runtimes: VoiceModel.runtimes,
            runtime: ModelRuntimeStore.shared.runtime(for: voice),
            onRuntime: { ModelRuntimeStore.shared.set($0, for: voice) },
            plain: plain
        )
    }
}

private func dots(_ n: Int) -> String {
    String(repeating: "●", count: n) + String(repeating: "○", count: max(0, 5 - n))
}

// MARK: - Shared tile

/// The card layout every model uses: radio button, name, facts, and download controls.
struct ModelTile: View {
    let name: String
    let recommended: Bool
    let summary: String
    let facts: [(symbol: String, text: String)]
    let state: ModelManager.State
    let selected: Bool
    var onSelect: () -> Void
    var onDownload: () -> Void
    var onDelete: (() -> Void)?
    /// Where the model can run; a picker appears when there's more than one choice.
    var runtimes: [ModelRuntime] = []
    var runtime: ModelRuntime? = nil
    var onRuntime: ((ModelRuntime) -> Void)? = nil
    /// No card background or border: a row in a Settings form, which draws its own.
    var plain = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .font(.title3)
                .foregroundStyle(selected ? Color.accentColor : .secondary)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(name).font(.headline)
                    if recommended {
                        Text("Recommended")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                    }
                }
                Text(summary).font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    ForEach(facts, id: \.text) { fact in
                        Label(fact.text, systemImage: fact.symbol)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                runtimeRow
            }

            Spacer()
            controls
        }
        .padding(plain ? 4 : 14)
        .background {
            if !plain {
                RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor))
            }
        }
        .overlay {
            if !plain {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: selected ? 2 : 1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }

    @ViewBuilder private var runtimeRow: some View {
        if let runtime {
            if runtimes.count > 1, let onRuntime {
                HStack(spacing: 6) {
                    Text("Runs on").font(.caption).foregroundStyle(.secondary)
                    Picker("Runs on", selection: Binding(get: { runtime }, set: onRuntime)) {
                        ForEach(runtimes) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .fixedSize()
                    .help(runtime.detail)
                }
                .padding(.top, 2)
            } else {
                Label("Runs on \(runtime.title)", systemImage: "cpu")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
    }

    @ViewBuilder private var controls: some View {
        switch state {
        case .notDownloaded:
            Button("Download", action: onDownload)
        case .downloading(let progress):
            VStack(alignment: .trailing, spacing: 4) {
                if let progress {
                    ProgressView(value: progress).frame(width: 120)
                    Text("\(Int(progress * 100))%").font(.caption).monospacedDigit()
                } else {
                    ProgressView().controlSize(.small)
                    Text("Downloading…").font(.caption)
                }
            }
        case .downloaded:
            HStack {
                Label("Ready", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
                if let onDelete {
                    Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Delete model")
                }
            }
        case .failed(let message):
            VStack(alignment: .trailing, spacing: 4) {
                Button("Retry", action: onDownload)
                Text(message).font(.caption).foregroundStyle(.red).lineLimit(2).frame(maxWidth: 180, alignment: .trailing)
            }
        }
    }
}
