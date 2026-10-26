import Foundation
import MLX
import MLXEmbedders
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers

// This file deliberately doesn't import SwiftData: both define `ModelConfiguration`.

/// EmbeddingGemma (300M, 8-bit MLX) through mlx-swift-lm's MLXEmbedders, already part of the
/// MLX package the app uses for chat. 100+ languages, 768-d vectors cut to 256 (Matryoshka).
///
/// EmbeddingGemma 2 needs a newer MLX than the app has today; when the packages are upgraded it
/// slots in as another `TextEmbedder` (see docs/EMBEDDINGS_PLAN.md §3.1).
final class GemmaEmbedder: TextEmbedder, @unchecked Sendable {
    static let repo = "mlx-community/embeddinggemma-300m-8bit"
    static let displayName = "EmbeddingGemma 300M"
    static let sizeLabel = "~330 MB"

    let modelID = "embeddinggemma-300m-8bit@256"
    let dimensions = 256
    /// Longer inputs are cut (the model reads up to 2,048 tokens).
    private let maxTokens = 2_048

    private let container: EmbedderModelContainer

    private init(container: EmbedderModelContainer) {
        self.container = container
    }

    /// Downloads the model into the Hugging Face cache the first time, then loads it.
    static func load(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> GemmaEmbedder {
        let container = try await EmbedderModelFactory.shared.loadContainer(
            from: #hubDownloader(),
            using: #huggingFaceTokenizerLoader(),
            configuration: ModelConfiguration(id: repo),
            progressHandler: { progress($0.fractionCompleted) }
        )
        return GemmaEmbedder(container: container)
    }

    /// Where the Hugging Face cache keeps the model (to check for it and to delete it).
    static var cacheFolder: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".cache/huggingface/hub/models--" + repo.replacingOccurrences(of: "/", with: "--"))
    }

    static var isDownloaded: Bool {
        let snapshots = cacheFolder.appendingPathComponent("snapshots")
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: snapshots.path)) ?? []
        return !contents.isEmpty
    }

    func embed(_ texts: [String], role: EmbeddingRole) async throws -> [[Float]] {
        let inputs = texts.map { role.format($0) }
        let dimensions = dimensions
        let maxTokens = maxTokens
        return try await container.perform { context in
            var results: [[Float]] = []
            results.reserveCapacity(inputs.count)
            // One text at a time: no padding, so padding can't leak into the attention.
            for text in inputs {
                var tokens = context.tokenizer.encode(text: text, addSpecialTokens: true)
                if tokens.count > maxTokens { tokens = Array(tokens.prefix(maxTokens)) }
                let input = MLXArray(tokens.map { Int32($0) })
                let output = context.model(input, positionIds: nil, tokenTypeIds: nil, attentionMask: nil)
                guard let pooled = output.pooledOutput else { throw EmbeddingError.noOutput }
                pooled.eval()
                let full = pooled.asArray(Float.self)
                results.append(VectorMath.truncateAndNormalize(full, to: dimensions))
            }
            return results
        }
    }
}
