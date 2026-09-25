import Foundation
import Combine

/// 串起「加载模型 → 拼 prompt → 流式生成 → 清洗输出」的编排层。
@MainActor
final class ChatEngine: ObservableObject {
    enum Phase: Equatable {
        case loadingModel
        /// 模型加载失败。整个 app 都没法用，只能重试。
        case loadFailed(String)
        case ready
        case generating
        /// 这一轮生成失败。模型还在，对话可以接着进行 —— 别和 loadFailed 混为一谈，
        /// 否则一次生成出错就会把人踢出对话界面。
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
    @Published private(set) var stats: Stats?
    /// 上下文占用比例，0…1。给界面画那条细进度条。
    @Published private(set) var contextUsage: Double = 0
    /// 上一次生成因为超长被裁掉了早期对话。
    @Published private(set) var didTrimHistory = false
    @Published private(set) var modelDescription: String?
    /// 模型加载进度，0…1。半个 GB 的权重要映射好几秒，界面得有个交代。
    @Published private(set) var loadProgress: Double = 0

    private let bridge = LlamaBridge()
    private var currentTask: Task<Void, Never>?
    private var pacer: StreamPacer?
    private var loadedModelPath: String?

    /// KV cache 当前对应哪个会话 —— cache 里存的是这个会话的历史，换会话必须重置。
    private var contextConversationID: UUID?
    /// KV 里已经有 system prompt 和至少一轮对话，下一轮可以走增量。
    private var hasOpenContext = false

    var isGenerating: Bool { phase == .generating }

    // MARK: - 模型

    func loadModel(at url: URL) async {
        if loadedModelPath == url.path, phase == .ready {
            return
        }

        currentTask?.cancel()
        phase = .loadingModel
        loadProgress = 0

        var config = LlamaBridge.Config()
        config.gpuLayers = AppSettings.gpuLayers
        config.contextSize = UInt32(AppSettings.contextSize)
        config.threadCount = Int32(AppSettings.threadCount)
        config.temperature = Float(AppSettings.temperature)
        config.topP = Float(AppSettings.topP)

        do {
            try await bridge.load(modelPath: url.path, config: config) { progress in
                Task { @MainActor [weak self] in
                    // 权重只是第一段。回调跑完之后还要建上下文 —— 分配 KV cache，
                    // 首次启动还要编译 Metal 内核 —— 那一段 llama.cpp 不报进度。
                    // 映射到 0…0.9，末尾留给它：进度条停在 90% 是实话，
                    // 停在 100% 却还要等，是在说已经好了。
                    self?.loadProgress = progress * 0.9
                }
            }
            loadedModelPath = url.path
            modelDescription = await bridge.modelInfo()?.description
            invalidateContext()
            loadProgress = 1
            phase = .ready
        } catch {
            loadedModelPath = nil
            phase = .loadFailed(error.localizedDescription)
        }
    }

    /// 标记 KV cache 不再可信，下次发消息会重建。
    func invalidateContext() {
        contextConversationID = nil
        hasOpenContext = false
        contextUsage = 0
    }

    // MARK: - 生成

    func send(_ text: String, store: ChatStore) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, phase == .ready, let conversationID = store.currentID else { return }

        store.append(ChatMessage(role: .user, text: trimmed), to: conversationID)
        generate(userMessage: trimmed, conversationID: conversationID, store: store)
    }

    /// 重新生成最后一条回复：撤掉上一轮问答，用同样的问题再问一次。
    func regenerate(store: ChatStore) {
        guard phase == .ready, let conversationID = store.currentID,
              let prompt = store.popLastExchange(in: conversationID) else { return }
        // KV 里还留着被撤销的那一轮，必须重建。
        invalidateContext()
        store.append(ChatMessage(role: .user, text: prompt), to: conversationID)
        generate(userMessage: prompt, conversationID: conversationID, store: store)
    }

    func stop() {
        currentTask?.cancel()
        // 连队列里还没放出去的也一并丢掉 —— 用户按的是停止，不是"放完再停"。
        pacer?.cancel()
        pacer = nil
    }

    private func generate(userMessage: String, conversationID: UUID, store: ChatStore) {
        currentTask?.cancel()
        streamingText = ""
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
                store: store
            )
        }
    }

    private func run(
        userMessage: String,
        history: [ChatMessage],
        conversationID: UUID,
        store: ChatStore
    ) async {
        var sanitizer = StreamSanitizer()
        let startedAt = Date()
        var firstTokenAt: Date?
        var generated = 0
        var truncated = false

        // 模型吐字的节奏很不均匀，直接往界面上灌就是一块一块地跳。
        // 交给 pacer 摊平成匀速，触觉反馈也跟着它走，才是稳定的节拍。
        let pacer = StreamPacer(
            onEmit: { [weak self] chunk in self?.streamingText += chunk },
            onTick: { Haptics.streamTick() }
        )
        self.pacer = pacer

        do {
            try await primeContext(
                userMessage: userMessage,
                history: history,
                conversationID: conversationID
            )

            loop: while true {
                if Task.isCancelled { break }
                let step = try await bridge.step()
                switch step {
                case .token(let piece):
                    generated += 1
                    if firstTokenAt == nil, !piece.isEmpty { firstTokenAt = Date() }
                    pacer.enqueue(sanitizer.consume(piece))
                case .endOfGeneration:
                    break loop
                case .contextFull, .tokenLimit:
                    truncated = true
                    break loop
                }
            }

            let tail = await bridge.drain()
            pacer.enqueue(sanitizer.consume(tail))
            pacer.enqueue(sanitizer.finish())
            // 等队列见底再收尾，否则最后一段会被下面的整体替换直接吞掉。
            await pacer.finish()
            self.pacer = nil

            let elapsed = Date().timeIntervalSince(firstTokenAt ?? startedAt)
            stats = Stats(
                firstTokenLatency: (firstTokenAt ?? startedAt).timeIntervalSince(startedAt),
                tokensPerSecond: elapsed > 0 ? Double(generated) / elapsed : 0,
                generatedTokens: generated
            )
            await finish(
                text: sanitizer.visibleText,
                truncated: truncated,
                conversationID: conversationID,
                store: store,
                cancelled: Task.isCancelled
            )
        } catch {
            // 生成到一半失败也要把已经吐出来的内容留下，不然用户白等。
            pacer.cancel()
            self.pacer = nil
            await finish(
                text: sanitizer.visibleText,
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
        conversationID: UUID
    ) async throws {
        let budget = AppSettings.maxReplyTokens
        let canExtend = hasOpenContext && contextConversationID == conversationID && !history.isEmpty

        if canExtend {
            let prompt = ChatPrompt.followUp(
                userMessage: userMessage,
                suppressThinking: true
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
            conversationID: conversationID
        )
    }

    private func rebuild(
        userMessage: String,
        history: [ChatMessage],
        conversationID: UUID
    ) async throws {
        let budget = AppSettings.maxReplyTokens
        var kept = history

        while true {
            await bridge.reset()
            let prompt = kept.isEmpty
                ? ChatPrompt.opening(
                    systemPrompt: AppSettings.systemPrompt,
                    userMessage: userMessage,
                    suppressThinking: true
                )
                : ChatPrompt.rebuild(
                    systemPrompt: AppSettings.systemPrompt,
                    history: kept,
                    userMessage: userMessage,
                    suppressThinking: true
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
        truncated: Bool,
        conversationID: UUID,
        store: ChatStore,
        cancelled: Bool
    ) async {
        await refreshContextUsage()
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        streamingText = ""

        guard !body.isEmpty else {
            // 一个字都没生成出来（比如立刻被取消），不要留一条空气泡。
            if cancelled { invalidateContext() }
            return
        }
        store.append(
            ChatMessage(role: .assistant, text: body, isTruncated: truncated),
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
