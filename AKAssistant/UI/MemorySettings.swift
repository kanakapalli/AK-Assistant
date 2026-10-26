import SwiftUI

/// Settings › Search & memory: the on-device search model, what gets indexed, and how Mac
/// commands are matched by meaning.
struct MemorySettingsSection: View {
    @Environment(Preferences.self) private var preferences
    @Environment(AppState.self) private var appState
    @State private var confirmDelete = false

    var body: some View {
        @Bindable var preferences = preferences
        let memory = appState.memory

        Section("Search & memory") {
            Toggle("Smart search & memory", isOn: Binding(
                get: { preferences.memoryEnabled },
                set: { on in
                    preferences.memoryEnabled = on
                    if on {
                        Task { await memory.enable() }
                    } else {
                        memory.disable()
                    }
                }
            ))
            Text("Understands meaning, not just exact words: find meetings and dictations by what was said, and run Mac commands phrased any way, in any language (“xcode kholo”, “awaaz kam karo”). Uses \(GemmaEmbedder.displayName) (\(GemmaEmbedder.sizeLabel), downloaded once). Everything stays on this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if preferences.memoryEnabled {
                LabeledContent("Search model") { ModelStateLabel(state: memory.embedding.state) }

                if let indexer = memory.indexer {
                    LabeledContent("Index") {
                        if indexer.isRunning && indexer.pending > 0 {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Indexing · \(indexer.pending) left")
                            }
                        } else {
                            Text("\(memory.entryCount.formatted()) passages")
                                .monospacedDigit()
                        }
                    }
                    if let error = indexer.lastError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                Toggle("Index meetings", isOn: $preferences.memoryIndexMeetings)
                    .onChange(of: preferences.memoryIndexMeetings) { memory.indexer?.sync() }
                Toggle("Index dictation and AI history", isOn: $preferences.memoryIndexHistory)
                    .onChange(of: preferences.memoryIndexHistory) { memory.indexer?.sync() }

                Picker("Commands said any way", selection: $preferences.commandMatching) {
                    ForEach(CommandMatching.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .onChange(of: preferences.commandMatching) { _, mode in
                    if mode != .off { Task { await memory.commands.prepare() } }
                }
                Text(preferences.commandMatching.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Rebuild index") { memory.rebuildIndex() }
                        .help("Embed everything again (use after changing what's indexed, or if search seems off).")
                    Button("Delete model and index…", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .confirmationDialog("Delete the search model and index?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                memory.deleteAll()
                preferences.memoryEnabled = false
            }
        } message: {
            Text("Meetings and history aren't touched. Turning smart search on again downloads the model and rebuilds the index.")
        }
    }
}

private struct ModelStateLabel: View {
    let state: EmbeddingService.State

    var body: some View {
        switch state {
        case .notDownloaded:
            Text("Not downloaded").foregroundStyle(.secondary)
        case .downloading(let fraction):
            HStack(spacing: 6) {
                ProgressView(value: fraction).frame(width: 90)
                Text("\(Int(fraction * 100))%").monospacedDigit()
            }
        case .notLoaded:
            Text("Downloaded · loads when needed").foregroundStyle(.secondary)
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading…")
            }
        case .ready:
            Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .lineLimit(2)
        }
    }
}
