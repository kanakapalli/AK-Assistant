import Foundation
import Observation

// Models the user adds themselves, from Hugging Face, a .zip download link, or a folder on this Mac.
//
// What each engine can run:
// - Speech to text (WhisperKit): Whisper models converted to WhisperKit's Core ML format, i.e. a folder
//   with AudioEncoder.mlmodelc, TextDecoder.mlmodelc and MelSpectrogram.mlmodelc.
// - AI assistant (MLX): chat models in MLX format, i.e. a folder with config.json, *.safetensors and
//   tokenizer files (anything from huggingface.co/mlx-community). GGUF files don't work with MLX.

/// One user-added model, saved in UserDefaults.
struct CustomModelRecord: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case speech, chat }

    enum Source: Codable, Hashable {
        /// Hugging Face repo. For speech, `variant` is the model's folder inside the repo.
        case huggingFace(repo: String, variant: String?)
        /// Copied into the app's Models folder (from a local folder or an unzipped download).
        case local(path: String, origin: String)
    }

    var id: String
    var kind: Kind
    var name: String
    var source: Source
    /// Chat models: let the model "think" before answering (slower; the thinking is hidden).
    var allowThinking = false
    var sizeLabel: String?

    var speechModel: SpeechModel {
        var repo = "", variant = "", summary = ""
        switch source {
        case .huggingFace(let r, let v):
            repo = r; variant = v ?? ""
            summary = "Custom model from huggingface.co/\(r)"
        case .local(_, let origin):
            summary = "Custom model from \(origin)"
        }
        return SpeechModel(
            id: id, name: name, engine: .whisperKit, variant: variant, repo: repo,
            sizeLabel: sizeLabel ?? "Custom", languages: "Depends on the model", summary: summary,
            speed: 0, accuracy: 0, isCustom: true
        )
    }

    var chatModel: ChatModel {
        var repo = "", summary = "", localPath: String?
        switch source {
        case .huggingFace(let r, _):
            repo = r
            summary = "Custom model from huggingface.co/\(r)"
        case .local(let path, let origin):
            localPath = path.isEmpty ? nil : path
            summary = "Custom model from \(origin)"
        }
        return ChatModel(
            id: id, name: name, repo: repo, sizeLabel: sizeLabel ?? "Custom", summary: summary,
            speed: 0, quality: 0,
            // End-of-reply markers used by the common model families; ones a model doesn't know are ignored.
            extraEOSTokens: ["<|im_end|>", "<|eot_id|>", "<end_of_turn>", "<turn|>", "<|end|>", "<|endoftext|>"],
            disableThinking: !allowThinking,
            isCustom: true, localPath: localPath
        )
    }
}

/// Keeps the list of user-added models. Views redraw when it changes.
@MainActor
@Observable
final class CustomModelStore {
    static let shared = CustomModelStore()

    private(set) var records: [CustomModelRecord] = []
    private let key = "customModels"

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([CustomModelRecord].self, from: data) {
            records = saved
        }
    }

    var speechModels: [SpeechModel] { records.filter { $0.kind == .speech }.map(\.speechModel) }
    var chatModels: [ChatModel] { records.filter { $0.kind == .chat }.map(\.chatModel) }

    func isCustom(_ id: String) -> Bool { records.contains { $0.id == id } }

    func add(_ record: CustomModelRecord) {
        records.removeAll { $0.id == record.id }
        records.append(record)
        save()
    }

    func update(_ id: String, _ change: (inout CustomModelRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        change(&records[index])
        save()
    }

    func remove(_ id: String) {
        records.removeAll { $0.id == id }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

enum CustomModelError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

/// Checks folders and Hugging Face repos before anything big is downloaded or copied.
enum CustomModelInspector {
    static let whisperKitFiles = ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc"]

    // MARK: Local folders

    /// Finds the folder that holds the model (the one picked, or one a few levels inside it).
    static func modelRoot(in folder: URL, kind: CustomModelRecord.Kind) throws -> URL {
        if let root = search(folder, kind: kind, depth: 0) { return root }
        let files = (try? FileManager.default.subpathsOfDirectory(atPath: folder.path)) ?? []
        switch kind {
        case .speech:
            if files.contains(where: { $0.hasSuffix(".bin") || $0.hasSuffix(".pt") || $0.hasSuffix(".safetensors") }) {
                throw CustomModelError.message("This looks like a regular Whisper model. Duck Keyboard needs the WhisperKit Core ML version (a folder with AudioEncoder.mlmodelc, TextDecoder.mlmodelc and MelSpectrogram.mlmodelc). You can convert one with Argmax's whisperkittools.")
            }
            throw CustomModelError.message("No WhisperKit model found. The folder needs AudioEncoder.mlmodelc, TextDecoder.mlmodelc and MelSpectrogram.mlmodelc.")
        case .chat:
            if files.contains(where: { $0.lowercased().hasSuffix(".gguf") }) {
                throw CustomModelError.message("GGUF models (LM Studio / Ollama) don't run with MLX. Look for an MLX version of the model, for example on huggingface.co/mlx-community.")
            }
            throw CustomModelError.message("No MLX model found. The folder needs config.json, .safetensors weights and tokenizer files.")
        }
    }

    private static func search(_ folder: URL, kind: CustomModelRecord.Kind, depth: Int) -> URL? {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: folder.path) else { return nil }
        switch kind {
        case .speech:
            if whisperKitFiles.allSatisfy({ items.contains($0) }) { return folder }
        case .chat:
            if items.contains("config.json"), items.contains(where: { $0.hasSuffix(".safetensors") }) { return folder }
        }
        guard depth < 3 else { return nil }
        for item in items.sorted() where !item.hasPrefix(".") && !item.hasSuffix(".mlmodelc") {
            let child = folder.appendingPathComponent(item, isDirectory: true)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: child.path, isDirectory: &isDir), isDir.boolValue,
               let found = search(child, kind: kind, depth: depth + 1) {
                return found
            }
        }
        return nil
    }

    // MARK: Hugging Face

    private struct RepoInfo: Decodable {
        struct Sibling: Decodable { let rfilename: String }
        let siblings: [Sibling]?
    }

    /// File names in a public Hugging Face repo.
    static func repoFiles(_ repo: String) async throws -> [String] {
        let trimmed = normalizedRepo(repo)
        guard trimmed.split(separator: "/").count == 2,
              let url = URL(string: "https://huggingface.co/api/models/\(trimmed)") else {
            throw CustomModelError.message("Enter the repo as owner/name, for example mlx-community/Mistral-7B-Instruct-v0.3-4bit.")
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw CustomModelError.message("Couldn't open \(trimmed) on Hugging Face. Check the name; private or gated repos aren't supported.")
        }
        let info = try JSONDecoder().decode(RepoInfo.self, from: data)
        return info.siblings?.map(\.rfilename) ?? []
    }

    /// WhisperKit model folders in a repo, e.g. "openai_whisper-small" in argmaxinc/whisperkit-coreml.
    static func whisperKitVariants(in repo: String) async throws -> [String] {
        let files = try await repoFiles(repo)
        let variants = Set(files.compactMap { path -> String? in
            guard let range = path.range(of: "/AudioEncoder.mlmodelc/") else { return nil }
            return String(path[..<range.lowerBound])
        })
        guard !variants.isEmpty else {
            throw CustomModelError.message("No WhisperKit models in this repo. It needs folders containing AudioEncoder.mlmodelc (like argmaxinc/whisperkit-coreml).")
        }
        return variants.sorted()
    }

    /// Fails fast (before a multi-GB download) if a repo isn't an MLX chat model.
    static func checkMLXRepo(_ repo: String) async throws {
        let files = try await repoFiles(repo)
        let hasConfig = files.contains("config.json")
        let hasWeights = files.contains { $0.hasSuffix(".safetensors") }
        if hasConfig && hasWeights { return }
        if files.contains(where: { $0.lowercased().hasSuffix(".gguf") }) {
            throw CustomModelError.message("This repo has GGUF files, which don't run with MLX. Search huggingface.co/mlx-community for an MLX version.")
        }
        throw CustomModelError.message("This repo isn't an MLX model (it needs config.json and .safetensors files at the top level).")
    }

    static func normalizedRepo(_ text: String) -> String {
        var repo = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://huggingface.co/", "http://huggingface.co/", "huggingface.co/"] where repo.hasPrefix(prefix) {
            repo.removeFirst(prefix.count)
        }
        // Drop things like "/tree/main" from a pasted browser URL.
        let parts = repo.split(separator: "/")
        if parts.count > 2 { repo = parts.prefix(2).joined(separator: "/") }
        return repo
    }

    // MARK: Zip links

    /// Downloads a .zip, unpacks it and returns the unpacked folder.
    static func downloadAndUnzip(_ link: String) async throws -> URL {
        guard let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            throw CustomModelError.message("Enter a full download link starting with https://")
        }
        let (downloaded, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw CustomModelError.message("The download failed (HTTP \(http.statusCode)).")
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("AKModel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let zip = work.appendingPathComponent("model.zip")
        try FileManager.default.moveItem(at: downloaded, to: zip)
        let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)

        // ditto ships with macOS and handles large zips, including Finder-made ones.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, unpacked.path]
        try process.run()
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                process.waitUntilExit()
                continuation.resume()
            }
        }
        try? FileManager.default.removeItem(at: zip)
        guard process.terminationStatus == 0 else {
            throw CustomModelError.message("Couldn't unzip the download. The link must point to a .zip file of the model folder.")
        }
        return unpacked
    }
}
