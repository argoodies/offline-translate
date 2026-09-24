import Foundation
import Combine

/// 串起「加载模型 → 拼 prompt → 流式生成 → 清洗输出」的编排层。
@MainActor
final class ChatEngine: ObservableObject {
    enum Phase: Equatable {
        case needsModel
        case loadingModel
        case ready
        case generating
        case failed(String)
    }

    struct Stats: Equatable {
        var firstTokenLatency: TimeInterval
        var tokensPerSecond: Double
        var generatedTokens: Int
    }

    // 模型随包安装，启动后必然会立刻加载，初始状态直接给加载中，避免闪一下空界面。
    @Published private(set) var phase: Phase = .loadingModel
    /// 正在生成的回复。生成期间界面从这里读，结束后才落进 ChatStore ——
    /// 每个 token 都改动会话数组会让整个消息列表重绘。
    @Published private(set) var streamingText = ""
    @Published private(set) var streamingReasoning: String?
    @Published private(set) var stats: Stats?
    /// 上下文占用比例，0…1。给界面画那条细进度条。
    @Published private(set) var contextUsage: Double = 0
    /// 上一次生成因为超长被裁掉了早期对话。
    @Published private(set) var didTrimHistory = false
    @Published private(set) var modelDescription: String?

    private let bridge = LlamaBridge()
    private var currentTask: Task<Void, Never>?
    private var loadedModelPath: String?
    private var loadedSignature: String?

    /// KV cache 当前对应哪个会话 —— cache 里存的是这个会话的历史，换会话必须重置。
    private var contextConversationID: UUID?
    /// KV 里已经有 system prompt 和至少一轮对话，下一轮可以走增量。
    private var hasOpenContext = false

    var isGenerating: Bool { phase == .generating }

    // MARK: - 模型

    func loadModel(at url: URL, settings: AppSettings) async {
        let signature = settings.runtimeSignature
        if loadedModelPath == url.path, loadedSignature == signature, phase == .ready {
            return
        }

        currentTask?.cancel()
        phase = .loadingModel

        var config = LlamaBridge.Config()
        config.contextSize = UInt32(settings.contextSize)
        config.threadCount = Int32(settings.threadCount)
        config.temperature = Float(settings.temperature)
        config.topP = Float(settings.topP)

        do {
            try await bridge.load(modelPath: url.path, config: config)
            loadedModelPath = url.path
            loadedSignature = signature
            modelDescription = await bridge.modelInfo()?.description
            invalidateContext()
            phase = .ready
        } catch {
            loadedModelPath = nil
            loadedSignature = nil
            phase = .failed(error.localizedDescription)
        }
    }

    func unloadModel() async {
        currentTask?.cancel()
        currentTask = nil
        await bridge.unload()
        loadedModelPath = nil
        loadedSignature = nil
        modelDescription = nil
        invalidateContext()
        phase = .needsModel
    }

    /// 标记 KV cache 不再可信，下次发消息会重建。
    func invalidateContext() {
        contextConversationID = nil
        hasOpenContext = false
        contextUsage = 0
    }

    // MARK: - 生成

    func send(_ text: String, store: ChatStore, settings: AppSettings) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, phase == .ready, let conversationID = store.currentID else { return }

        store.append(ChatMessage(role: .user, text: trimmed), to: conversationID)
        generate(userMessage: trimmed, conversationID: conversationID, store: store, settings: settings)
    }

    /// 重新生成最后一条回复：撤掉上一轮问答，用同样的问题再问一次。
    func regenerate(store: ChatStore, settings: AppSettings) {
        guard phase == .ready, let conversationID = store.currentID,
              let prompt = store.popLastExchange(in: conversationID) else { return }
        // KV 里还留着被撤销的那一轮，必须重建。
        invalidateContext()
        store.append(ChatMessage(role: .user, text: prompt), to: conversationID)
        generate(userMessage: prompt, conversationID: conversationID, store: store, settings: settings)
    }

    func stop() {
        currentTask?.cancel()
    }

    private func generate(userMessage: String, conversationID: UUID, store: ChatStore, settings: AppSettings) {
        currentTask?.cancel()
        streamingText = ""
        streamingReasoning = nil
        stats = nil
        didTrimHistory = false
        phase = .generating

        // 这条 user 消息已经进 store 了，历史要排除它自己。
        let history = store.currentMessages.dropLast()

        currentTask = Task { [weak self] in
            await self?.run(
                userMessage: userMessage,
                history: Array(history),
                conversationID: conversationID,
                store: store,
                settings: settings
            )
        }
    }

    private func run(
        userMessage: String,
        history: [ChatMessage],
        conversationID: UUID,
        store: ChatStore,
        settings: AppSettings
    ) async {
        var sanitizer = StreamSanitizer()
        let startedAt = Date()
        var firstTokenAt: Date?
        var generated = 0
        var truncated = false
        var buffer = ""
        var lastFlush = startedAt

        do {
            try await primeContext(
                userMessage: userMessage,
                history: history,
                conversationID: conversationID,
                settings: settings
            )

            loop: while true {
                if Task.isCancelled { break }
                let step = try await bridge.step()
                switch step {
                case .token(let piece):
                    generated += 1
                    if firstTokenAt == nil, !piece.isEmpty { firstTokenAt = Date() }
                    buffer += sanitizer.consume(piece)
                    let now = Date()
                    // 逐 token 刷新 @Published 会让 SwiftUI 每秒重绘几十次，按时间片合并。
                    if now.timeIntervalSince(lastFlush) >= 0.05 {
                        if !buffer.isEmpty {
                            streamingText += buffer
                            buffer = ""
                        }
                        streamingReasoning = settings.showReasoning ? sanitizer.trimmedReasoning : nil
                        lastFlush = now
                    }
                case .endOfGeneration:
                    break loop
                case .contextFull, .tokenLimit:
                    truncated = true
                    break loop
                }
            }

            let tail = await bridge.drain()
            buffer += sanitizer.consume(tail)
            buffer += sanitizer.finish()
            streamingText += buffer

            let elapsed = Date().timeIntervalSince(firstTokenAt ?? startedAt)
            stats = Stats(
                firstTokenLatency: (firstTokenAt ?? startedAt).timeIntervalSince(startedAt),
                tokensPerSecond: elapsed > 0 ? Double(generated) / elapsed : 0,
                generatedTokens: generated
            )
            await finish(
                text: sanitizer.visibleText,
                reasoning: settings.showReasoning ? sanitizer.trimmedReasoning : nil,
                truncated: truncated,
                conversationID: conversationID,
                store: store,
                cancelled: Task.isCancelled
            )
        } catch {
            // 生成到一半失败也要把已经吐出来的内容留下，不然用户白等。
            await finish(
                text: sanitizer.visibleText,
                reasoning: settings.showReasoning ? sanitizer.trimmedReasoning : nil,
                truncated: true,
                conversationID: conversationID,
                store: store,
                cancelled: true
            )
            phase = .failed(error.localizedDescription)
            invalidateContext()
            return
        }

        phase = .ready
    }

    /// 把这一轮的 prompt 喂进 KV cache。能增量就增量，装不下就裁掉早期对话重建。
    private func primeContext(
        userMessage: String,
        history: [ChatMessage],
        conversationID: UUID,
        settings: AppSettings
    ) async throws {
        let budget = settings.maxReplyTokens
        let canExtend = hasOpenContext && contextConversationID == conversationID && !history.isEmpty

        if canExtend {
            let prompt = ChatPrompt.followUp(
                userMessage: userMessage,
                suppressThinking: !settings.showReasoning
            )
            do {
                try await bridge.extend(prompt: prompt, maxNewTokens: budget)
                await refreshContextUsage()
                return
            } catch LlamaError.promptTooLong {
                // 上下文满了，退到重建路径把早期对话裁掉。
                didTrimHistory = true
            }
        }

        try await rebuild(
            userMessage: userMessage,
            history: history,
            conversationID: conversationID,
            settings: settings
        )
    }

    private func rebuild(
        userMessage: String,
        history: [ChatMessage],
        conversationID: UUID,
        settings: AppSettings
    ) async throws {
        let budget = settings.maxReplyTokens
        var kept = history

        while true {
            await bridge.reset()
            let prompt = kept.isEmpty
                ? ChatPrompt.opening(
                    systemPrompt: settings.systemPrompt,
                    userMessage: userMessage,
                    suppressThinking: !settings.showReasoning
                )
                : ChatPrompt.rebuild(
                    systemPrompt: settings.systemPrompt,
                    history: kept,
                    userMessage: userMessage,
                    suppressThinking: !settings.showReasoning
                )
            do {
                try await bridge.extend(prompt: prompt, maxNewTokens: budget)
                contextConversationID = conversationID
                hasOpenContext = true
                await refreshContextUsage()
                return
            } catch LlamaError.promptTooLong {
                guard !kept.isEmpty else {
                    // 历史已经空了还装不下，那是这条消息本身太长。
                    let limit = await bridge.contextLimit
                    invalidateContext()
                    throw LlamaError.promptTooLong(promptTokens: 0, contextSize: limit)
                }
                // 每次砍掉最早的一轮问答。
                kept.removeFirst(min(2, kept.count))
                didTrimHistory = true
            }
        }
    }

    private func finish(
        text: String,
        reasoning: String?,
        truncated: Bool,
        conversationID: UUID,
        store: ChatStore,
        cancelled: Bool
    ) async {
        await refreshContextUsage()
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        streamingText = ""
        streamingReasoning = nil

        guard !body.isEmpty else {
            // 一个字都没生成出来（比如立刻被取消），不要留一条空气泡。
            if cancelled { invalidateContext() }
            return
        }
        store.append(
            ChatMessage(role: .assistant, text: body, reasoning: reasoning, isTruncated: truncated),
            to: conversationID
        )
        if cancelled {
            // 提前停下时 KV 里的内容和落盘的消息对不上，下轮重建。
            invalidateContext()
        }
    }

    private func refreshContextUsage() async {
        let used = await bridge.usedContext
        let limit = await bridge.contextLimit
        contextUsage = limit > 0 ? min(1, Double(used) / Double(limit)) : 0
    }
}
