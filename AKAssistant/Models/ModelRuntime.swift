import Foundation
import Observation
import CoreML

/// Where a model runs. Each model lists the options it supports; the user picks one per model in Settings.
enum ModelRuntime: String, Codable, CaseIterable, Identifiable {
    case gpu            // Core ML on the GPU
    case neuralEngine   // Core ML on the Neural Engine
    case mlx            // Apple's MLX framework (always on the GPU)
    case cpu            // Core ML on the CPU only

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gpu: return "GPU (Core ML)"
        case .neuralEngine: return "Neural Engine"
        case .mlx: return "MLX (GPU)"
        case .cpu: return "CPU"
        }
    }

    /// Short name for chips and menus.
    var shortTitle: String {
        switch self {
        case .gpu: return "GPU"
        case .neuralEngine: return "Neural Engine"
        case .mlx: return "MLX"
        case .cpu: return "CPU"
        }
    }

    var symbol: String {
        switch self {
        case .gpu: return "square.stack.3d.up"
        case .neuralEngine: return "brain"
        case .mlx: return "bolt"
        case .cpu: return "cpu"
        }
    }

    /// The Core ML compute units for this choice (MLX doesn't use Core ML).
    var computeUnits: MLComputeUnits {
        switch self {
        case .gpu, .mlx: return .cpuAndGPU
        case .neuralEngine: return .cpuAndNeuralEngine
        case .cpu: return .cpuOnly
        }
    }

    var detail: String {
        switch self {
        case .gpu: return "Core ML on the GPU. Loads quickly."
        case .neuralEngine: return "Uses the least power and leaves the GPU free for the AI. The first load can take a while."
        case .mlx: return "Apple's MLX framework on the GPU. Separate download."
        case .cpu: return "The processor only. Slowest, but keeps the GPU and Neural Engine free for other work."
        }
    }
}

extension ModelRuntime {
    /// MLX speech-to-text needs the mlx-audio-swift package. Without it the MLX option is hidden
    /// for speech models (the AI model's MLX is a different package and always available).
    static var mlxSpeechAvailable: Bool {
        #if canImport(MLXAudioSTT)
        return true
        #else
        return false
        #endif
    }
}

extension SpeechModel {
    /// The runtimes that can actually be used in this build.
    var availableRuntimes: [ModelRuntime] {
        let usable = runtimes.filter { $0 != .mlx || ModelRuntime.mlxSpeechAvailable }
        return usable.isEmpty ? [.gpu] : usable
    }
}

/// The MLX version of a speech model (run with mlx-audio-swift), when one exists.
struct MLXSpeechSpec: Hashable {
    /// Hugging Face repo with the MLX weights.
    let repo: String
    /// mlx-audio-swift model family: "parakeet", "whisper" or "nemotron".
    let family: String
    let sizeLabel: String
}

/// Remembers which runtime the user picked for each model.
@MainActor
@Observable
final class ModelRuntimeStore {
    static let shared = ModelRuntimeStore()

    private(set) var choices: [String: ModelRuntime] = [:]
    private let key = "modelRuntimes"

    private init() {
        if let saved = UserDefaults.standard.dictionary(forKey: key) as? [String: String] {
            choices = saved.compactMapValues(ModelRuntime.init(rawValue:))
        }
    }

    func runtime(for model: SpeechModel) -> ModelRuntime {
        pick(choices[model.id], from: model.availableRuntimes)
    }

    func runtime(for voice: VoiceModel) -> ModelRuntime {
        pick(choices["voice:" + voice.id], from: VoiceModel.runtimes)
    }

    func set(_ runtime: ModelRuntime, for model: SpeechModel) { save(runtime, key: model.id) }
    func set(_ runtime: ModelRuntime, for voice: VoiceModel) { save(runtime, key: "voice:" + voice.id) }

    /// A saved choice the model doesn't support (anymore) falls back to the model's first option.
    private func pick(_ saved: ModelRuntime?, from options: [ModelRuntime]) -> ModelRuntime {
        if let saved, options.contains(saved) { return saved }
        return options.first ?? .gpu
    }

    private func save(_ runtime: ModelRuntime, key id: String) {
        choices[id] = runtime
        UserDefaults.standard.set(choices.mapValues(\.rawValue), forKey: key)
    }
}
