import Foundation
import Observation
import WhisperKit
import FluidAudio

/// Downloads, tracks and deletes every model the app uses: speech-to-text, the AI chat model and the voice.
/// Everything lives on this Mac after download.
@MainActor
@Observable
final class ModelManager {
    enum State: Equatable {
        case notDownloaded
        case downloading(progress: Double?)   // nil = indeterminate
        case downloaded
        case failed(String)
    }

    private(set) var states: [String: State] = [:]

    /// Model id -> local folder (WhisperKit) or a marker for FluidAudio-managed models.
    private var localPaths: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "modelPaths") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "modelPaths") }
    }

    static let modelsDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("AK Assistant/Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Where FluidAudio keeps all Parakeet models (one subfolder per model).
    private static let fluidAudioModelDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("FluidAudio/Models", isDirectory: true)
    }()

    init() {
        removeRetiredModels()
        for model in ModelCatalog.all {
            states[model.id] = isOnDisk(model) ? .downloaded : .notDownloaded
            if model.mlx != nil {
                let key = Self.mlxKey(model)
                states[key] = isOnDisk(key: key) ? .downloaded : .notDownloaded
            }
        }
        for model in AssistantCatalog.chatModels {
            states[Self.key(model)] = isOnDisk(model) ? .downloaded : .notDownloaded
        }
        for voice in AssistantCatalog.voiceModels {
            states[Self.key(voice)] = localFolder(for: voice) != nil ? .downloaded : .notDownloaded
        }
    }

    /// Speech models keep separate files per runtime: Core ML (Neural Engine and GPU share them)
    /// and MLX. State, download and delete always refer to the runtime picked for the model.
    func storageKey(_ model: SpeechModel) -> String {
        ModelRuntimeStore.shared.runtime(for: model) == .mlx ? Self.mlxKey(model) : model.id
    }

    private static func mlxKey(_ model: SpeechModel) -> String { model.id + "@mlx" }

    func state(of model: SpeechModel) -> State {
        states[storageKey(model)] ?? .notDownloaded
    }

    func isDownloaded(_ model: SpeechModel) -> Bool {
        state(of: model) == .downloaded
    }

    func localFolder(for model: SpeechModel) -> URL? {
        guard let path = localPaths[model.id], model.engine == .whisperKit else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    var diskUsageLabel: String {
        // Custom chat models copied from a folder already sit inside modelsDirectory; don't count them twice.
        let chatBytes = AssistantCatalog.chatModels.filter { $0.localPath == nil }.reduce(Int64(0)) { $0 + Self.folderSize(LLMService.cacheFolder(for: $1)) }
        let bytes = Self.folderSize(Self.modelsDirectory) + Self.folderSize(Self.fluidAudioModelDirectory) + chatBytes
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: - Download

    func download(_ model: SpeechModel) async {
        if case .downloading = state(of: model) { return }
        let key = storageKey(model)
        states[key] = .downloading(progress: 0)

        do {
            #if canImport(MLXAudioSTT)
            if key != model.id, let spec = model.mlx {
                // MLX weights come from Hugging Face (cache: ~/.cache/huggingface/hub); no percentage is reported.
                states[key] = .downloading(progress: nil)
                try await MLXSpeechEngine.download(spec)
                var paths = localPaths
                paths[key] = Self.huggingFaceCacheFolder(spec.repo).path
                localPaths = paths
                states[key] = .downloaded
                return
            }
            #endif
            switch model.engine {
            case .whisperKit:
                let modelID = key
                let folder = try await WhisperKit.download(
                    variant: model.variant,
                    downloadBase: Self.modelsDirectory,
                    from: model.repo,
                    progressCallback: { progress in
                        let fraction = progress.fractionCompleted
                        Task { @MainActor [weak self] in
                            // Progress updates can arrive after the download has finished; without this
                            // check a late one flips the model back to "downloading" and onboarding's
                            // Continue button stays disabled.
                            if case .downloading = self?.states[modelID] {
                                self?.states[modelID] = .downloading(progress: fraction)
                            }
                        }
                    }
                )
                var paths = localPaths
                paths[key] = folder.path
                localPaths = paths

            case .nemotronStreaming:
                let modelID = key
                try await NemotronStreamingEngine.download { fraction in
                    Task { @MainActor [weak self] in
                        if case .downloading = self?.states[modelID] {
                            self?.states[modelID] = .downloading(progress: fraction)
                        }
                    }
                }
                var paths = localPaths
                paths[key] = NemotronStreamingEngine.modelFolder.path
                localPaths = paths

            case .parakeet:
                // FluidAudio downloads into its own cache (Application Support/FluidAudio/Models).
                let modelID = key
                let folder = try await AsrModels.download(
                    version: ParakeetEngine.version(for: model),
                    progressHandler: { progress in
                        let fraction = progress.fractionCompleted
                        Task { @MainActor [weak self] in
                            if case .downloading = self?.states[modelID] {
                                self?.states[modelID] = .downloading(progress: fraction)
                            }
                        }
                    }
                )
                var paths = localPaths
                paths[key] = folder.path
                localPaths = paths
            }
            states[key] = .downloaded
        } catch {
            states[key] = .failed(error.localizedDescription)
        }
    }

    // MARK: - Delete

    func delete(_ model: SpeechModel) {
        let key = storageKey(model)
        if let path = localPaths[key] {
            try? FileManager.default.removeItem(atPath: path)
        }
        var paths = localPaths
        paths[key] = nil
        localPaths = paths
        states[key] = .notDownloaded
    }

    /// Where swift-huggingface keeps a repo (the same cache the AI models use).
    static func huggingFaceCacheFolder(_ repo: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub/models--" + repo.replacingOccurrences(of: "/", with: "--"), isDirectory: true)
    }

    // MARK: - AI chat models (MLX, Hugging Face cache)

    private static func key(_ model: ChatModel) -> String { "chat:" + model.id }
    private static func key(_ voice: VoiceModel) -> String { "voice:" + voice.id }

    func state(of model: ChatModel) -> State {
        states[Self.key(model)] ?? .notDownloaded
    }

    func isDownloaded(_ model: ChatModel) -> Bool {
        state(of: model) == .downloaded
    }

    func download(_ model: ChatModel) async {
        let key = Self.key(model)
        if case .downloading = states[key] { return }
        states[key] = .downloading(progress: 0)
        do {
            try await LLMService.download(model) { fraction in
                Task { @MainActor [weak self] in
                    // Keep a completed download from flipping back to "downloading".
                    if case .downloading = self?.states[key] {
                        self?.states[key] = .downloading(progress: fraction)
                    }
                }
            }
            var paths = localPaths
            paths[key] = LLMService.cacheFolder(for: model).path
            localPaths = paths
            states[key] = .downloaded
        } catch {
            states[key] = .failed(error.localizedDescription)
        }
    }

    func delete(_ model: ChatModel) {
        let key = Self.key(model)
        try? FileManager.default.removeItem(at: LLMService.cacheFolder(for: model))
        var paths = localPaths
        paths[key] = nil
        localPaths = paths
        states[key] = .notDownloaded
    }

    private func isOnDisk(_ model: ChatModel) -> Bool {
        localPaths[Self.key(model)] != nil
            && FileManager.default.fileExists(atPath: LLMService.cacheFolder(for: model).path)
    }

    // MARK: - Voice models (Qwen3-TTS via TTSKit)

    static let voiceDirectory: URL = modelsDirectory.appendingPathComponent("Voice", isDirectory: true)

    func state(of voice: VoiceModel) -> State {
        states[Self.key(voice)] ?? .notDownloaded
    }

    func isDownloaded(_ voice: VoiceModel) -> Bool {
        state(of: voice) == .downloaded
    }

    func localFolder(for voice: VoiceModel) -> URL? {
        guard let path = localPaths[Self.key(voice)], FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    func download(_ voice: VoiceModel) async {
        let key = Self.key(voice)
        if case .downloading = states[key] { return }
        states[key] = .downloading(progress: 0)
        do {
            let folder = try await SpeechService.download(variant: voice.id, to: Self.voiceDirectory) { fraction in
                Task { @MainActor [weak self] in
                    if case .downloading = self?.states[key] {
                        self?.states[key] = .downloading(progress: fraction)
                    }
                }
            }
            var paths = localPaths
            paths[key] = folder.path
            localPaths = paths
            states[key] = .downloaded
        } catch {
            states[key] = .failed(error.localizedDescription)
        }
    }

    func delete(_ voice: VoiceModel) {
        let key = Self.key(voice)
        if let folder = localFolder(for: voice) {
            try? FileManager.default.removeItem(at: folder)
        }
        var paths = localPaths
        paths[key] = nil
        localPaths = paths
        states[key] = .notDownloaded
    }

    // MARK: - Helpers

    /// Deletes files of speech models this version no longer offers, so they don't take up disk space.
    private func removeRetiredModels() {
        var paths = localPaths
        for id in ModelCatalog.retiredIDs {
            guard let path = paths[id] else { continue }
            try? FileManager.default.removeItem(atPath: path)
            paths[id] = nil
        }
        localPaths = paths
    }

    private func isOnDisk(_ model: SpeechModel) -> Bool {
        isOnDisk(key: model.id)
    }

    private func isOnDisk(key: String) -> Bool {
        guard let path = localPaths[key] else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    private static func folderSize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let size = (try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0
            total += Int64(size)
        }
        return total
    }
}

// MARK: - Custom models (see CustomModels.swift)

extension ModelManager {
    /// Where custom models copied from a folder or a .zip link are kept.
    static let customDirectory: URL = modelsDirectory.appendingPathComponent("Custom", isDirectory: true)

    /// What an "Add custom model" request points at.
    enum CustomSource {
        case huggingFace(repo: String, variant: String?)
        case zipLink(String)
        case folder(URL)
    }

    /// Adds a model, downloads or copies it, then loads it once to prove it works.
    /// On failure nothing is left behind and the error explains what's wrong.
    /// `status` reports each step for the sheet ("Downloading…", "Checking the model…").
    @discardableResult
    func addCustomModel(
        kind: CustomModelRecord.Kind,
        name: String,
        source: CustomSource,
        allowThinking: Bool,
        status: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        let id = "custom-" + UUID().uuidString.prefix(8).lowercased()
        let store = CustomModelStore.shared
        var record = CustomModelRecord(id: id, kind: kind, name: name, source: .local(path: "", origin: ""), allowThinking: allowThinking)
        let stateKey = kind == .speech ? id : "chat:" + id

        do {
            switch source {
            case .huggingFace(let rawRepo, let variant):
                let repo = CustomModelInspector.normalizedRepo(rawRepo)
                status("Checking \(repo) on Hugging Face…")
                if kind == .chat {
                    try await CustomModelInspector.checkMLXRepo(repo)
                } else {
                    let variants = try await CustomModelInspector.whisperKitVariants(in: repo)
                    guard let variant, variants.contains(variant) else {
                        throw CustomModelError.message("Pick one of the models in this repo: \(variants.prefix(6).joined(separator: ", "))")
                    }
                }
                record.source = .huggingFace(repo: repo, variant: variant)
                store.add(record)
                status("Downloading… large models can take several minutes. Progress also shows on the model's card.")
                if kind == .speech {
                    await download(record.speechModel)
                    if case .failed(let message) = state(of: record.speechModel) { throw CustomModelError.message(message) }
                } else {
                    await download(record.chatModel)   // MLX loads the model after downloading, which also checks it
                    if case .failed(let message) = state(of: record.chatModel) { throw CustomModelError.message(message) }
                }

            case .zipLink(let link):
                status("Downloading the .zip…")
                let unpacked = try await CustomModelInspector.downloadAndUnzip(link)
                defer { try? FileManager.default.removeItem(at: unpacked.deletingLastPathComponent()) }
                let host = URL(string: link)?.host ?? "a download link"
                try await installLocal(from: unpacked, move: true, origin: host, into: &record, stateKey: stateKey, status: status)

            case .folder(let folder):
                let accessing = folder.startAccessingSecurityScopedResource()
                defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
                try await installLocal(from: folder, move: false, origin: folder.lastPathComponent, into: &record, stateKey: stateKey, status: status)
            }

            if kind == .speech {
                // Loading once proves the files are a working WhisperKit model.
                status("Checking the model…")
                guard let folder = localFolder(for: record.speechModel) else {
                    throw CustomModelError.message("The model files are missing after download.")
                }
                _ = try await WhisperKitEngine(modelFolder: folder, useNeuralEngine: false)
                store.update(id) { $0.sizeLabel = ByteCountFormatter.string(fromByteCount: Self.folderSize(folder), countStyle: .file) }
            } else {
                store.update(id) { [folder = LLMService.cacheFolder(for: record.chatModel)] in
                    $0.sizeLabel = ByteCountFormatter.string(fromByteCount: Self.folderSize(folder), countStyle: .file)
                }
            }
            return id
        } catch {
            // Undo everything so a broken model doesn't linger in the list. Only delete files once the
            // record points at them (an empty local path must never reach delete()).
            if let saved = store.records.first(where: { $0.id == id }) {
                if kind == .speech { delete(saved.speechModel) } else { delete(saved.chatModel) }
            }
            try? FileManager.default.removeItem(at: Self.customDirectory.appendingPathComponent(id, isDirectory: true))
            store.remove(id)
            states[stateKey] = nil
            throw Self.friendly(error, kind: kind)
        }
    }

    /// Copies (or moves, for an unzipped download) the model folder into the app, and for chat models
    /// loads it once to check MLX can run it.
    private func installLocal(
        from source: URL, move: Bool, origin: String,
        into record: inout CustomModelRecord, stateKey: String,
        status: @escaping @MainActor (String) -> Void
    ) async throws {
        let root = try CustomModelInspector.modelRoot(in: source, kind: record.kind)
        let destination = Self.customDirectory.appendingPathComponent(record.id, isDirectory: true)
        status(move ? "Installing…" : "Copying the model into AK Assistant…")
        states[stateKey] = .downloading(progress: nil)
        let customDirectory = Self.customDirectory
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            try fm.createDirectory(at: customDirectory, withIntermediateDirectories: true)
            if move { try fm.moveItem(at: root, to: destination) } else { try fm.copyItem(at: root, to: destination) }
        }.value

        record.source = .local(path: destination.path, origin: origin)
        CustomModelStore.shared.add(record)
        var paths = localPaths
        paths[stateKey] = destination.path
        localPaths = paths

        if record.kind == .chat {
            status("Checking the model…")
            try await LLMService.download(record.chatModel) { _ in }   // loads from the folder; fails if MLX can't run it
        }
        states[stateKey] = .downloaded
    }

    /// Removes a custom model: its files, its card and (if it was selected) the selection.
    func removeCustom(_ id: String) {
        guard let record = CustomModelStore.shared.records.first(where: { $0.id == id }) else { return }
        switch record.kind {
        case .speech: delete(record.speechModel)
        case .chat: delete(record.chatModel)
        }
        CustomModelStore.shared.remove(id)
    }

    /// Turns library errors into something a person can act on.
    private static func friendly(_ error: Error, kind: CustomModelRecord.Kind) -> Error {
        if error is CustomModelError { return error }
        let text = error.localizedDescription
        if text.localizedCaseInsensitiveContains("Unsupported model type") {
            return CustomModelError.message("MLX doesn't support this model's architecture yet (\(text)). Try a Llama, Qwen, Gemma, Mistral or Phi model from mlx-community.")
        }
        let what = kind == .speech ? "WhisperKit" : "MLX"
        return CustomModelError.message("\(what) couldn't load this model: \(text)")
    }
}
