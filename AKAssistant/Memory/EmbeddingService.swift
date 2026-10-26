import Foundation
import Observation
import os

/// Loads the search model when needed, keeps it warm while in use, unloads it after a while.
@MainActor
@Observable
final class EmbeddingService {
    enum State: Equatable {
        case notDownloaded
        case downloading(Double)
        case notLoaded          // downloaded, not in memory
        case loading
        case ready
        case failed(String)
    }

    private(set) var state: State

    @ObservationIgnored private var embedder: GemmaEmbedder?
    @ObservationIgnored private var loadTask: Task<GemmaEmbedder, Error>?
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    private let log = Logger(subsystem: "com.natfirst.akassistant", category: "Memory")

    /// Free the model's memory after this long without use.
    var idleUnloadInterval: TimeInterval = 15 * 60

    let modelID = "embeddinggemma-300m-8bit@256"
    let dimensions = 256

    init() {
        state = GemmaEmbedder.isDownloaded ? .notLoaded : .notDownloaded
    }

    var isDownloaded: Bool { GemmaEmbedder.isDownloaded }
    var isLoaded: Bool { embedder != nil }

    /// Downloads (first time) and loads the model. Concurrent callers share one load.
    @discardableResult
    func prepare() async throws -> GemmaEmbedder {
        if let embedder {
            scheduleIdleUnload()
            return embedder
        }
        if let loadTask { return try await loadTask.value }

        state = GemmaEmbedder.isDownloaded ? .loading : .downloading(0)
        let started = Date()
        let task = Task<GemmaEmbedder, Error> {
            try await GemmaEmbedder.load { fraction in
                Task { @MainActor [weak self] in
                    guard let self, case .downloading = self.state else { return }
                    self.state = .downloading(fraction)
                }
            }
        }
        loadTask = task
        do {
            let loaded = try await task.value
            embedder = loaded
            loadTask = nil
            state = .ready
            log.info("Search model ready in \(Date().timeIntervalSince(started), format: .fixed(precision: 1))s")
            scheduleIdleUnload()
            return loaded
        } catch {
            loadTask = nil
            state = .failed(error.localizedDescription)
            log.error("Search model failed to load: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    func embed(_ texts: [String], role: EmbeddingRole) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        let embedder = try await prepare()
        let vectors = try await embedder.embed(texts, role: role)
        scheduleIdleUnload()
        return vectors
    }

    /// Only if the model is already in memory (latency-critical paths like commands never wait
    /// for a load; they fall back and start the load in the background instead).
    func embedIfLoaded(_ texts: [String], role: EmbeddingRole) async -> [[Float]]? {
        guard let embedder else {
            if isDownloaded { Task { try? await self.prepare() } }
            return nil
        }
        let vectors = try? await embedder.embed(texts, role: role)
        scheduleIdleUnload()
        return vectors
    }

    func unload() {
        embedder = nil
        loadTask?.cancel()
        loadTask = nil
        idleTask?.cancel()
        state = isDownloaded ? .notLoaded : .notDownloaded
    }

    func deleteModel() {
        unload()
        try? FileManager.default.removeItem(at: GemmaEmbedder.cacheFolder)
        state = .notDownloaded
    }

    private func scheduleIdleUnload() {
        idleTask?.cancel()
        idleTask = Task { [weak self, idleUnloadInterval] in
            try? await Task.sleep(for: .seconds(idleUnloadInterval))
            guard !Task.isCancelled, let self else { return }
            self.embedder = nil
            self.state = self.isDownloaded ? .notLoaded : .notDownloaded
            self.log.info("Search model unloaded after being idle")
        }
    }
}
