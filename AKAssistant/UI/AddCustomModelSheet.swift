import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// "Add custom model" for speech-to-text (WhisperKit) or the AI assistant (MLX):
/// from a Hugging Face repo, a .zip download link, or a folder on this Mac.
struct AddCustomModelSheet: View {
    let kind: CustomModelRecord.Kind

    @Environment(\.dismiss) private var dismiss
    @Environment(Preferences.self) private var preferences
    @Environment(ModelManager.self) private var modelManager

    enum SourceTab: String, CaseIterable, Identifiable {
        case huggingFace = "Hugging Face"
        case link = "Download link"
        case folder = "Folder on this Mac"
        var id: String { rawValue }
    }

    @State private var tab: SourceTab = .huggingFace
    @State private var name = ""
    @State private var repo = ""
    @State private var variants: [String] = []
    @State private var variant = ""
    @State private var findingVariants = false
    @State private var link = ""
    @State private var folder: URL?
    @State private var dropTargeted = false
    @State private var allowThinking = false
    @State private var working = false
    @State private var status = ""
    @State private var error: String?

    private var isSpeech: Bool { kind == .speech }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            Picker("Source", selection: $tab) {
                ForEach(SourceTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(working)

            Group {
                switch tab {
                case .huggingFace: huggingFaceFields
                case .link: linkFields
                case .folder: folderFields
                }
            }
            .disabled(working)

            TextField("Name shown in the app (optional)", text: $name)
                .textFieldStyle(.roundedBorder)
                .disabled(working)

            if !isSpeech {
                Toggle("Let the model think before answering (Qwen3, DeepSeek-R1 and similar)", isOn: $allowThinking)
                    .disabled(working)
                Text("Off is faster. When on, the thinking is hidden and only the answer is shown and spoken.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if working {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(status).font(.callout).foregroundStyle(.secondary)
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(working)
                Button("Add Model") { Task { await add() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdd || working)
            }
        }
        .padding(24)
        .frame(width: 560)
        .onChange(of: tab) { error = nil }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(isSpeech ? "Add a speech-to-text model" : "Add an AI model")
                .font(.title2.weight(.semibold))
            Text(isSpeech
                 ? "Needs a Whisper model in WhisperKit's Core ML format: a folder with AudioEncoder.mlmodelc, TextDecoder.mlmodelc and MelSpectrogram.mlmodelc. Regular PyTorch or GGML Whisper files won't work until converted with whisperkittools."
                 : "Needs a chat model in MLX format: a folder with config.json, .safetensors weights and tokenizer files, like anything from huggingface.co/mlx-community. GGUF files (LM Studio, Ollama) won't work.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Sources

    @ViewBuilder private var huggingFaceFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField(isSpeech ? "argmaxinc/whisperkit-coreml" : "mlx-community/Mistral-7B-Instruct-v0.3-4bit", text: $repo)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if isSpeech { Task { await findVariants() } } }
                if isSpeech {
                    Button(findingVariants ? "Looking…" : "Find models") { Task { await findVariants() } }
                        .disabled(repo.isEmpty || findingVariants)
                }
            }
            .onChange(of: repo) { variants = []; variant = "" }

            if isSpeech && !variants.isEmpty {
                Picker("Model", selection: $variant) {
                    ForEach(variants, id: \.self) { Text($0).tag($0) }
                }
            }
            Text(isSpeech
                 ? "Paste a repo name or its huggingface.co link, then pick the model folder inside it."
                 : "Paste a repo name or its huggingface.co link. It's checked before anything is downloaded.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var linkFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("https://example.com/my-model.zip", text: $link)
                .textFieldStyle(.roundedBorder)
            Text("A direct link to a .zip of the model folder. The download shows no percentage, so large models can take a while.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var folderFields: some View {
        VStack(spacing: 10) {
            Image(systemName: folder == nil ? "folder.badge.plus" : "folder.fill")
                .font(.system(size: 28))
                .foregroundStyle(Color.accentColor)
            if let folder {
                Text(folder.lastPathComponent).font(.headline)
                Text(folder.deletingLastPathComponent().path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("Drop the model folder here").font(.headline)
            }
            Button(folder == nil ? "Choose Folder…" : "Choose Another…", action: chooseFolder)
            Text("The folder is copied into AK Assistant, so you can delete or move the original afterwards.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.4))
        )
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, url.hasDirectoryPath || isDirectory(url) else { return false }
            pick(url)
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    // MARK: - Actions

    private var canAdd: Bool {
        switch tab {
        case .huggingFace: return !repo.trimmingCharacters(in: .whitespaces).isEmpty && (!isSpeech || !variant.isEmpty)
        case .link: return link.lowercased().hasPrefix("http")
        case .folder: return folder != nil
        }
    }

    private func findVariants() async {
        findingVariants = true
        error = nil
        defer { findingVariants = false }
        do {
            variants = try await CustomModelInspector.whisperKitVariants(in: repo)
            variant = variants.first ?? ""
        } catch {
            variants = []
            self.error = error.localizedDescription
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = isSpeech ? "Choose the WhisperKit model folder" : "Choose the MLX model folder"
        if panel.runModal() == .OK, let url = panel.url { pick(url) }
    }

    private func pick(_ url: URL) {
        folder = url
        error = nil
        if name.isEmpty { name = url.lastPathComponent }
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    private var defaultName: String {
        switch tab {
        case .huggingFace:
            let repoName = CustomModelInspector.normalizedRepo(repo).split(separator: "/").last.map(String.init) ?? "Custom model"
            return isSpeech && !variant.isEmpty ? variant : repoName
        case .link:
            let file = URL(string: link)?.deletingPathExtension().lastPathComponent ?? ""
            return file.isEmpty ? "Custom model" : file
        case .folder:
            return folder?.lastPathComponent ?? "Custom model"
        }
    }

    private func add() async {
        working = true
        error = nil
        status = "Starting…"
        defer { working = false }

        let source: ModelManager.CustomSource
        switch tab {
        case .huggingFace: source = .huggingFace(repo: repo, variant: isSpeech ? variant : nil)
        case .link: source = .zipLink(link)
        case .folder:
            guard let folder else { return }
            source = .folder(folder)
        }
        let displayName = name.trimmingCharacters(in: .whitespaces).isEmpty ? defaultName : name

        do {
            let id = try await modelManager.addCustomModel(
                kind: kind, name: displayName, source: source, allowThinking: allowThinking
            ) { status = $0 }
            // Use the new model right away.
            if isSpeech { preferences.selectedModelID = id } else { preferences.chatModelID = id }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
