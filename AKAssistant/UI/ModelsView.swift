import SwiftUI

struct ModelsView: View {
    @Environment(Preferences.self) private var preferences
    @Environment(ModelManager.self) private var modelManager
    @State private var pendingDelete: PendingDelete?

    /// Something the user asked to delete, waiting for confirmation.
    private struct PendingDelete: Identifiable {
        let id = UUID()
        let name: String
        let perform: () -> Void
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Every model runs entirely on this Mac. Download the ones you want and pick which to use.")
                    .foregroundStyle(.secondary)

                section("Speech to text", "Turns your voice into text, for dictation and for questions to the AI.") {
                    ForEach(ModelCatalog.all) { model in
                        ModelCard(model: model, selected: preferences.selectedModelID == model.id) {
                            preferences.selectedModelID = model.id
                        } onDelete: {
                            pendingDelete = PendingDelete(name: model.name) { modelManager.delete(model) }
                        }
                    }
                }

                section("AI assistant", "Answers the questions you ask with the AI hotkey.") {
                    ForEach(AssistantCatalog.chatModels) { model in
                        ChatModelCard(model: model, selected: preferences.chatModelID == model.id) {
                            preferences.chatModelID = model.id
                        } onDelete: {
                            pendingDelete = PendingDelete(name: model.name) { modelManager.delete(model) }
                        }
                    }
                }

                section("Voice", "Reads the AI's answers aloud.") {
                    ForEach(AssistantCatalog.voiceModels) { voice in
                        VoiceModelCard(voice: voice, selected: preferences.voiceModelID == voice.id) {
                            preferences.voiceModelID = voice.id
                        } onDelete: {
                            pendingDelete = PendingDelete(name: voice.name) { modelManager.delete(voice) }
                        }
                    }
                }

                Text("Disk used by models: \(modelManager.diskUsageLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .navigationTitle("Models")
        .confirmationDialog(
            "Delete \(pendingDelete?.name ?? "model")?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { item in
            Button("Delete", role: .destructive) { item.perform() }
        }
    }

    private func section<Content: View>(_ title: String, _ subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3.weight(.semibold))
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
            content()
        }
    }
}

// MARK: - Cards for each kind of model

/// A speech-to-text model card.
struct ModelCard: View {
    @Environment(ModelManager.self) private var modelManager

    let model: SpeechModel
    let selected: Bool
    var onSelect: () -> Void
    var onDelete: (() -> Void)? = nil

    var body: some View {
        ModelTile(
            name: model.name,
            recommended: model.id == ModelCatalog.defaultModel.id,
            summary: model.summary,
            facts: [
                ("internaldrive", model.sizeLabel),
                ("globe", model.languages),
                ("hare", "Speed \(dots(model.speed))"),
                ("target", "Accuracy \(dots(model.accuracy))"),
            ],
            state: modelManager.state(of: model),
            selected: selected,
            onSelect: onSelect,
            onDownload: { Task { await modelManager.download(model) } },
            onDelete: onDelete
        )
    }
}

/// An AI chat model card.
struct ChatModelCard: View {
    @Environment(ModelManager.self) private var modelManager

    let model: ChatModel
    let selected: Bool
    var onSelect: () -> Void
    var onDelete: (() -> Void)? = nil

    var body: some View {
        ModelTile(
            name: model.name,
            recommended: model.id == AssistantCatalog.defaultChatModel.id,
            summary: model.summary,
            facts: [
                ("internaldrive", model.sizeLabel),
                ("hare", "Speed \(dots(model.speed))"),
                ("brain", "Quality \(dots(model.quality))"),
            ],
            state: modelManager.state(of: model),
            selected: selected,
            onSelect: onSelect,
            onDownload: { Task { await modelManager.download(model) } },
            onDelete: onDelete
        )
    }
}

/// A text-to-speech voice model card.
struct VoiceModelCard: View {
    @Environment(ModelManager.self) private var modelManager

    let voice: VoiceModel
    let selected: Bool
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
            onDelete: onDelete
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
            }

            Spacer()
            controls
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: selected ? 2 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
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
