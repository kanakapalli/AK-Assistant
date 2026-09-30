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

    /// Where FluidAudio caches Parakeet by default.
    private static let fluidAudioModelDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("FluidAudio/Models/parakeet-tdt-0.6b-v3-coreml", isDirectory: true)
    }()

    init() {
        for model in ModelCatalog.all {
            states[model.id] = isOnDisk(model) ? .downloaded : .notDownloaded
        }
        for model in AssistantCatalog.chatModels {
            states[Self.key(model)] = isOnDisk(model) ? .downloaded : .notDownloaded
        }
        for voice in AssistantCatalog.voiceModels {
            states[Self.key(voice)] = localFolder(for: voice) != nil ? .downloaded : .notDownloaded
        }
    }

    func state(of model: SpeechModel) -> State {
        states[model.id] ?? .notDownloaded
    }

    func isDownloaded(_ model: SpeechModel) -> Bool {
        state(of: model) == .downloaded
    }

    func localFolder(for model: SpeechModel) -> URL? {
        guard let path = localPaths[model.id], model.engine == .whisperKit else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    var diskUsageLabel: String {
        let chatBytes = AssistantCatalog.chatModels.reduce(Int64(0)) { $0 + Self.folderSize(LLMService.cacheFolder(for: $1)) }
        let bytes = Self.folderSize(Self.modelsDirectory) + Self.folderSize(Self.fluidAudioModelDirectory) + chatBytes
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: - Download

    func download(_ model: SpeechModel) async {
        if case .downloading = state(of: model) { return }
        states[model.id] = .downloading(progress: model.engine == .whisperKit ? 0 : nil)

        do {
            switch model.engine {
            case .whisperKit:
                let modelID = model.id
                let folder = try await WhisperKit.download(
                    variant: model.variant,
                    downloadBase: Self.modelsDirectory,
                    from: model.repo,
                    progressCallback: { progress in
                        let fraction = progress.fractionCompleted
                        Task { @MainActor [weak self] in
                            self?.states[modelID] = .downloading(progress: fraction)
                        }
                    }
                )
                var paths = localPaths
                paths[model.id] = folder.path
                localPaths = paths

            case .parakeet:
                // FluidAudio downloads into its own cache and compiles the Core ML models.
                _ = try await AsrModels.downloadAndLoad(version: .v3)
                var paths = localPaths
                paths[model.id] = Self.fluidAudioModelDirectory.path
                localPaths = paths
            }
            states[model.id] = .downloaded
        } catch {
            states[model.id] = .failed(error.localizedDescription)
        }
    }

    // MARK: - Delete

    func delete(_ model: SpeechModel) {
        if let path = localPaths[model.id] {
            try? FileManager.default.removeItem(atPath: path)
        }
        var paths = localPaths
        paths[model.id] = nil
        localPaths = paths
        states[model.id] = .notDownloaded
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

    private func isOnDisk(_ model: SpeechModel) -> Bool {
        guard let path = localPaths[model.id] else { return false }
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
