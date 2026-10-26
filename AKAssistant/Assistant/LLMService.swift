import Foundation
import os
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers

/// Runs a local chat model (MLX, from Hugging Face) and keeps a short conversation going.
///
/// This file deliberately doesn't import WhisperKit/TTSKit: those packages bundle their own
/// tokenizer types, and keeping the imports apart avoids name clashes.
@MainActor
final class LLMService {
    private var container: ModelContainer?
    private var session: ChatSession?
    private var loadedModelID: String?
    private var loadingTask: Task<ModelContainer, Error>?
    private var loadingModelID: String?
    private var lastUse = Date.distantPast
    /// Whether the current conversation was started with the Mac-command instructions.
    private var sessionAllowsActions = false
    private var idleTask: Task<Void, Never>?
    private let log = Logger(subsystem: "com.natfirst.akassistant", category: "Assistant")

    /// Follow-up questions within this window continue the same conversation.
    var conversationTimeout: TimeInterval = 5 * 60
    /// Free the model's memory after this long without a question.
    /// Reloading a multi-GB model takes several seconds, so keep it around for a while.
    var idleUnloadInterval: TimeInterval = 30 * 60

    static let instructions = """
        You are AK Assistant, a helpful voice assistant running privately on the user's Mac. \
        Answer in a friendly, natural tone. Keep answers short, usually one to three sentences, \
        unless the user asks for more detail. Your answer may be read aloud, so don't use markdown, \
        tables, code blocks or bullet lists unless the user asks for them.
        """

    /// Added when Mac commands are on. Common commands are recognised before the AI is asked
    /// (CommandParser); this lets the model hand back ones phrased in other ways or other languages.
    @MainActor static var actionInstructions: String {
        """
        You can also control this Mac. If the user wants something done on the Mac (open or quit an app, \
        open a website, search the web, set a timer or reminder, change the volume or brightness, take a \
        screenshot, lock the screen and so on), reply with exactly one line and nothing else, in this form:
        ACTION: <short English command>
        Use simple commands like these: \(ToolCatalog.phrasesForModel).
        For example "fire up the coding app from Apple" becomes "ACTION: open Xcode", and \
        "xcode kholo" becomes "ACTION: open Xcode". Only use ACTION when the user wants an action on the Mac. \
        For questions, chatting or writing, answer normally and never mention ACTION.
        """
    }

    static func configuration(for model: ChatModel) -> ModelConfiguration {
        if let path = model.localPath {
            return ModelConfiguration(directory: URL(fileURLWithPath: path, isDirectory: true), extraEOSTokens: model.extraEOSTokens)
        }
        return ModelConfiguration(id: model.repo, extraEOSTokens: model.extraEOSTokens)
    }

    /// Downloads the model into the Hugging Face cache (~/.cache/huggingface/hub).
    /// Loading it once also checks the files are complete.
    static func download(_ model: ChatModel, progress: @escaping @Sendable (Double) -> Void) async throws {
        let configuration = configuration(for: model)
        _ = try await #huggingFaceLoadModelContainer(
            configuration: configuration,
            progressHandler: { p in progress(p.fractionCompleted) }
        )
    }

    /// Where the Hugging Face cache keeps this model, used to check for and delete it.
    static func cacheFolder(for model: ChatModel) -> URL {
        if let path = model.localPath { return URL(fileURLWithPath: path, isDirectory: true) }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let name = "models--" + model.repo.replacingOccurrences(of: "/", with: "--")
        return home.appendingPathComponent(".cache/huggingface/hub/\(name)", isDirectory: true)
    }

    // MARK: - Asking

    /// Loads the model if needed, so the first question doesn't wait on it.
    /// If a load is already running (the hotkey preloads while you talk), this waits for it
    /// instead of starting a second load of the same model.
    func prepare(_ model: ChatModel) async throws {
        if loadedModelID == model.id, container != nil { return }
        if let loadingTask, loadingModelID == model.id {
            let loaded = try await loadingTask.value
            container = loaded
            loadedModelID = model.id
            return
        }
        unload()
        log.info("Loading chat model \(model.repo, privacy: .public)")
        let started = Date()
        let configuration = Self.configuration(for: model)
        let task = Task<ModelContainer, Error> {
            try await #huggingFaceLoadModelContainer(configuration: configuration)
        }
        loadingTask = task
        loadingModelID = model.id
        defer {
            if loadingModelID == model.id { loadingTask = nil; loadingModelID = nil }
        }
        let loaded = try await task.value
        container = loaded
        loadedModelID = model.id
        scheduleIdleUnload()
        log.info("Chat model ready in \(Date().timeIntervalSince(started), format: .fixed(precision: 1))s")
    }

    /// Streams the answer to a question, a few words at a time.
    func ask(_ question: String, model: ChatModel, allowActions: Bool = false) async throws -> AsyncThrowingStream<String, Error> {
        try await prepare(model)
        guard let container else { throw AssistantError.modelNotLoaded }

        if Date().timeIntervalSince(lastUse) > conversationTimeout {
            session = nil   // long pause: start a fresh conversation
        }
        if session != nil, sessionAllowsActions != allowActions {
            session = nil   // Mac commands were switched on or off
        }
        if session == nil {
            var parameters = GenerateParameters()
            parameters.maxTokens = 500
            parameters.temperature = 0.7
            session = ChatSession(
                container,
                instructions: allowActions ? Self.instructions + "\n\n" + Self.actionInstructions : Self.instructions,
                generateParameters: parameters,
                additionalContext: model.disableThinking ? ["enable_thinking": false] : nil
            )
            sessionAllowsActions = allowActions
        }
        lastUse = Date()
        scheduleIdleUnload()
        return session!.streamResponse(to: question)
    }

    /// A one-off answer that doesn't touch the spoken conversation (used for meeting notes).
    func generate(_ prompt: String, instructions: String, model: ChatModel, maxTokens: Int,
                  temperature: Float = 0.3) async throws -> String {
        try await prepare(model)
        guard let container else { throw AssistantError.modelNotLoaded }
        var parameters = GenerateParameters()
        parameters.maxTokens = maxTokens
        parameters.temperature = temperature   // low: notes and corrections should stick to the text
        let oneOff = ChatSession(
            container,
            instructions: instructions,
            generateParameters: parameters,
            additionalContext: model.disableThinking ? ["enable_thinking": false] : nil
        )
        var text = ""
        for try await chunk in oneOff.streamResponse(to: prompt) {
            if Task.isCancelled { break }
            text += chunk
        }
        scheduleIdleUnload()
        return AnswerCleaner.forDisplay(text)
    }

    /// Forget the conversation so the next question starts fresh.
    func newConversation() {
        session = nil
    }

    func unload() {
        session = nil
        container = nil
        loadedModelID = nil
        loadingTask?.cancel()
        loadingTask = nil
        loadingModelID = nil
        idleTask?.cancel()
    }

    private func scheduleIdleUnload() {
        idleTask?.cancel()
        idleTask = Task { [weak self, idleUnloadInterval] in
            try? await Task.sleep(for: .seconds(idleUnloadInterval))
            guard !Task.isCancelled else { return }
            self?.unload()
        }
    }
}

enum AssistantError: LocalizedError {
    case modelNotLoaded
    case modelNotDownloaded(String)

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded: return "The AI model isn't loaded"
        case .modelNotDownloaded(let name): return "Download \(name) first"
        }
    }
}
