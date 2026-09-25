import Foundation
import llama

/// 对 llama.cpp C API 的最小封装。
///
/// llama_context 不是线程安全的，所以整个类型是 actor：同一时刻只有一个调用方能推进解码。
/// 生成走 "prepare 一次、step 多次" 的模型，而不是内部 while 循环 —— 调用方每步 await 一次，
/// 于是取消、UI 刷新、超时都由调用方自然控制。
actor LlamaBridge {
    struct Config {
        var contextSize: UInt32 = 2048
        /// 单次 llama_decode 提交的最大 token 数，prompt 会按它分块喂入。
        var batchSize: UInt32 = 512
        var threadCount: Int32 = Config.defaultThreadCount
        var temperature: Float = 0.2
        var topP: Float = 0.9
        var topK: Int32 = 40
        var minP: Float = 0.05
        var seed: UInt32 = 0xFFFFFFFF  // LLAMA_DEFAULT_SEED

        /// 性能核数量；iPhone 上开满所有核反而会被调度器降频，留一个给系统。
        static var defaultThreadCount: Int32 {
            Int32(max(2, min(6, ProcessInfo.processInfo.activeProcessorCount - 1)))
        }
    }

    enum Step {
        /// 解出了可显示的文本（可能为空：token 落在多字节字符中间时会先缓冲）。
        case token(String)
        /// 模型吐出了 EOS / <|im_end|>，正常收尾。
        case endOfGeneration
        /// 撞到 n_ctx 上限，输出被截断。
        case contextFull
        /// 撞到调用方给的 maxTokens 上限。
        case tokenLimit
    }

    struct ModelInfo {
        var contextLength: Int32
        var vocabularySize: Int32
        var description: String
    }

    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var vocab: OpaquePointer?
    private var sampler: UnsafeMutablePointer<llama_sampler>?
    private var batch = llama_batch()
    private var batchAllocated = false

    private var config = Config()
    /// 下一个 token 在 KV cache 里的位置。
    private var cursor: llama_pos = 0
    private var generatedCount = 0
    private var maxNewTokens = 512
    /// token 切片可能把一个 UTF-8 字符劈成两半（中日韩几乎必然发生），先攒着再解码。
    private var pendingBytes: [UInt8] = []

    private static var backendReady = false

    var isLoaded: Bool { model != nil && context != nil }

    // MARK: - 生命周期

    func load(modelPath: String, config: Config = Config()) throws {
        unload()
        self.config = config

        if !Self.backendReady {
            // llama.cpp 默认把每条 log 打到 stderr，设备上没人看，还会拖慢生成。
            llama_log_set({ _, _, _ in }, nil)
            llama_backend_init()
            Self.backendReady = true
        }

        var modelParams = llama_model_default_params()
        // iOS 上 Metal 后端可用，0.8B 全量 offload 到 GPU；模拟器没有 Metal，会自动回落 CPU。
        modelParams.n_gpu_layers = 99
        // mmap 让 500MB 权重按页加载，常驻内存远低于文件大小 —— iOS 的内存上限很紧。
        // 不要用 MLOCK：把整个模型钉在 RAM 里，iOS 会直接因内存超限杀掉 app。
        modelParams.load_mode = LLAMA_LOAD_MODE_MMAP

        guard let loadedModel = llama_model_load_from_file(modelPath, modelParams) else {
            throw LlamaError.modelLoadFailed(URL(fileURLWithPath: modelPath).lastPathComponent)
        }
        model = loadedModel
        vocab = llama_model_get_vocab(loadedModel)

        var contextParams = llama_context_default_params()
        contextParams.n_ctx = config.contextSize
        contextParams.n_batch = config.batchSize
        contextParams.n_ubatch = config.batchSize
        contextParams.n_threads = config.threadCount
        contextParams.n_threads_batch = config.threadCount

        guard let createdContext = llama_init_from_model(loadedModel, contextParams) else {
            llama_model_free(loadedModel)
            model = nil
            vocab = nil
            throw LlamaError.contextCreationFailed
        }
        context = createdContext

        batch = llama_batch_init(Int32(config.batchSize), 0, 1)
        batchAllocated = true
        buildSampler()
    }

    func unload() {
        if let sampler {
            llama_sampler_free(sampler)
            self.sampler = nil
        }
        if batchAllocated {
            llama_batch_free(batch)
            batch = llama_batch()
            batchAllocated = false
        }
        if let context {
            llama_free(context)
            self.context = nil
        }
        if let model {
            llama_model_free(model)
            self.model = nil
        }
        vocab = nil
        cursor = 0
        generatedCount = 0
        pendingBytes.removeAll()
    }

    func modelInfo() -> ModelInfo? {
        guard let model, let vocab else { return nil }
        var buffer = [CChar](repeating: 0, count: 256)
        let written = llama_model_desc(model, &buffer, 256)
        let description = written > 0 ? String(cString: buffer) : "unknown"
        return ModelInfo(
            contextLength: llama_model_n_ctx_train(model),
            vocabularySize: llama_vocab_n_tokens(vocab),
            description: description
        )
    }

    // MARK: - 生成

    /// 当前 KV cache 里已经占了多少 token。
    var usedContext: Int { Int(cursor) }

    var contextLimit: Int {
        guard let context else { return 0 }
        return Int(llama_n_ctx(context))
    }

    /// 丢掉整个 KV cache，回到空白对话。
    func reset() {
        guard let context else { return }
        llama_memory_clear(llama_get_memory(context), true)
        cursor = 0
        generatedCount = 0
        pendingBytes.removeAll()
        if let sampler {
            llama_sampler_reset(sampler)
        }
    }

    /// 在已有 KV cache 之后追加一段 prompt 并解码，返回这段 prompt 的 token 数。
    ///
    /// 多轮对话的关键：只喂新增的部分。每轮都把完整历史重新 decode 一遍，第十轮的首字延迟
    /// 会是第一轮的十倍 —— 而 KV cache 里本来就存着前面所有轮的状态。
    @discardableResult
    func extend(prompt: String, maxNewTokens: Int) throws -> Int {
        guard let context else { throw LlamaError.notLoaded }

        generatedCount = 0
        pendingBytes.removeAll()
        self.maxNewTokens = maxNewTokens

        // parseSpecial: prompt 里的 <|im_start|> 等控制符要被识别成单个 token，不能当字面量。
        // addSpecial: ChatML 模板自己带了全部边界符，再让 tokenizer 追加 BOS 会重复。
        let tokens = try tokenize(prompt, addSpecial: false, parseSpecial: true)
        let limit = Int(llama_n_ctx(context))
        guard Int(cursor) + tokens.count + maxNewTokens <= limit else {
            throw LlamaError.promptTooLong(promptTokens: Int(cursor) + tokens.count, contextSize: limit)
        }
        try decode(tokens: tokens)
        return tokens.count
    }

    /// 生成下一个 token。调用方应循环调用直到拿到非 `.token` 的结果。
    func step() throws -> Step {
        guard let context, let sampler, let vocab else { throw LlamaError.notLoaded }

        if generatedCount >= maxNewTokens {
            return .tokenLimit
        }
        if Int(cursor) >= Int(llama_n_ctx(context)) {
            return .contextFull
        }

        // -1 = 上次 decode 的最后一个输出位置。sample 内部已经做了 accept，不要再手动 accept。
        let token = llama_sampler_sample(sampler, context, -1)
        if llama_vocab_is_eog(vocab, token) {
            return .endOfGeneration
        }

        generatedCount += 1
        pendingBytes.append(contentsOf: piece(for: token))
        let text = flushDecodableText() ?? ""

        try decode(tokens: [token])
        return .token(text)
    }

    /// 生成结束后调用，取出仍卡在 UTF-8 缓冲里的尾巴。
    func drain() -> String {
        guard !pendingBytes.isEmpty else { return "" }
        let text = String(decoding: pendingBytes, as: UTF8.self)
        pendingBytes.removeAll()
        return text
    }

    // MARK: - 内部实现

    private func buildSampler() {
        if let sampler {
            llama_sampler_free(sampler)
        }
        let chain = llama_sampler_chain_init(llama_sampler_chain_default_params())
        if config.temperature <= 0 {
            // 翻译默认走贪心：同一句输入每次都给同一个译文，用户重试时不会看到结果乱跳。
            llama_sampler_chain_add(chain, llama_sampler_init_greedy())
        } else {
            llama_sampler_chain_add(chain, llama_sampler_init_top_k(config.topK))
            llama_sampler_chain_add(chain, llama_sampler_init_top_p(config.topP, 1))
            llama_sampler_chain_add(chain, llama_sampler_init_min_p(config.minP, 1))
            llama_sampler_chain_add(chain, llama_sampler_init_temp(config.temperature))
            llama_sampler_chain_add(chain, llama_sampler_init_dist(config.seed))
        }
        sampler = chain
    }

    private func tokenize(_ text: String, addSpecial: Bool, parseSpecial: Bool) throws -> [llama_token] {
        guard let vocab else { throw LlamaError.notLoaded }
        let byteCount = text.utf8.count
        // 最坏情况每个字节一个 token，再留点余量给可能追加的特殊 token。
        let capacity = byteCount + 8
        var tokens = [llama_token](repeating: 0, count: capacity)
        let count = text.withCString { pointer in
            llama_tokenize(vocab, pointer, Int32(byteCount), &tokens, Int32(capacity), addSpecial, parseSpecial)
        }
        guard count >= 0 else { throw LlamaError.tokenizationFailed }
        return Array(tokens.prefix(Int(count)))
    }

    private func decode(tokens: [llama_token]) throws {
        guard let context, !tokens.isEmpty else { return }
        let chunkSize = Int(config.batchSize)
        var index = 0
        while index < tokens.count {
            let end = min(index + chunkSize, tokens.count)
            batch.n_tokens = 0
            for position in index..<end {
                // 只有整个 prompt 的最后一个 token 需要 logits —— 那是我们要采样的位置。
                append(token: tokens[position], wantsLogits: position == tokens.count - 1)
            }
            let status = llama_decode(context, batch)
            guard status == 0 else {
                // 1 = KV cache 放不下这一批，语义上等同于上下文用尽。
                throw status == 1 ? LlamaError.contextExhausted : LlamaError.decodeFailed(status)
            }
            index = end
        }
    }

    private func append(token: llama_token, wantsLogits: Bool) {
        let slot = Int(batch.n_tokens)
        batch.token[slot] = token
        batch.pos[slot] = cursor
        batch.n_seq_id[slot] = 1
        batch.seq_id[slot]![0] = 0
        batch.logits[slot] = wantsLogits ? 1 : 0
        batch.n_tokens += 1
        cursor += 1
    }

    private func piece(for token: llama_token) -> [UInt8] {
        guard let vocab else { return [] }
        var buffer = [CChar](repeating: 0, count: 64)
        var written = llama_token_to_piece(vocab, token, &buffer, 64, 0, false)
        if written < 0 {
            // 负数返回值是"需要这么大的 buffer"。
            buffer = [CChar](repeating: 0, count: Int(-written))
            written = llama_token_to_piece(vocab, token, &buffer, -written, 0, false)
            guard written >= 0 else { return [] }
        }
        return buffer.prefix(Int(written)).map { UInt8(bitPattern: $0) }
    }

    /// 取出缓冲里能构成完整 UTF-8 的最长前缀，剩下的半个字符留到下一个 token。
    private func flushDecodableText() -> String? {
        guard !pendingBytes.isEmpty else { return nil }
        // UTF-8 字符最长 4 字节，所以最多回退 3 个字节就能找到完整边界。
        let maxBacktrack = min(3, pendingBytes.count - 1)
        for backtrack in 0...maxBacktrack {
            let cut = pendingBytes.count - backtrack
            if let text = String(bytes: pendingBytes[0..<cut], encoding: .utf8) {
                pendingBytes.removeFirst(cut)
                return text.isEmpty ? nil : text
            }
        }
        // 攒了 4 个以上字节还解不出来，说明是真的坏字节而不是半个字符，丢掉以免无限增长。
        if pendingBytes.count > 4 {
            let text = String(decoding: pendingBytes, as: UTF8.self)
            pendingBytes.removeAll()
            return text
        }
        return nil
    }
}

enum LlamaError: LocalizedError {
    case notLoaded
    case modelLoadFailed(String)
    case contextCreationFailed
    case tokenizationFailed
    case decodeFailed(Int32)
    case contextExhausted
    case promptTooLong(promptTokens: Int, contextSize: Int)

    var errorDescription: String? {
        switch self {
        case .notLoaded:
            return L("The model is not loaded yet.")
        case .modelLoadFailed(let name):
            return L("Could not load \(name). The install may be damaged — please reinstall.")
        case .contextCreationFailed:
            return L("Failed to create the inference context. The device may be low on memory.")
        case .tokenizationFailed:
            return L("Tokenization failed.")
        case .decodeFailed(let code):
            return L("Inference failed (code \(code)).")
        case .contextExhausted:
            return L("The context is full. Please start a new chat.")
        case .promptTooLong(let promptTokens, let contextSize):
            return L("This conversation is too long (\(promptTokens) tokens, limit \(contextSize)). Please start a new chat.")
        }
    }
}
