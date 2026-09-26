import Foundation
import os
import llama

/// 对 llama.cpp C API 的最小封装。
///
/// llama_context 不是线程安全的，所以整个类型是 actor：同一时刻只有一个调用方能推进解码。
/// 生成走 "prepare 一次、step 多次" 的模型，而不是内部 while 循环 —— 调用方每步 await 一次，
/// 于是取消、UI 刷新、超时都由调用方自然控制。
actor LlamaBridge {
    struct Config {
        /// 交给 Metal 的层数。99 等于全部。
        ///
        /// 全量 offload 时 llama.cpp 要把整段 mmap 包成 GPU buffer，半个 GB 的页
        /// 得在加载时全部落地 —— mmap 的「按页取用」这时候不成立，启动就慢在这儿。
        /// 留几层在 CPU 上，那几层的权重才是真的按需读，启动能省一些。
        /// 代价是每生成一个 token，那几层都要走一遍 CPU。
        var gpuLayers: Int32 = 99
        /// 权重怎么读进来。见 `AppSettings.loadMode`。
        var loadMode: llama_load_mode = LLAMA_LOAD_MODE_MMAP
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

    /// 加载分两步，界面要如实说现在在哪一步，所以两步各有一个回调。
    ///
    /// - `onProgress`：读权重的进度，0…1。只有这一步 llama.cpp 会报进度。
    /// - `onPreparingContext`：权重读完了，开始建上下文 —— 分配 KV cache、建计算图，
    ///   首次启动还要编 Metal 内核。这一步没有进度可报，只能说一声开始了。
    func load(
        modelPath: String,
        config: Config = Config(),
        onProgress: ((Double) -> Void)? = nil,
        onPreparingContext: (() -> Void)? = nil
    ) throws {
        unload()
        self.config = config

        if !Self.backendReady {
            // llama.cpp 默认把每条 log 打到 stderr，设备上没人看，还会拖慢生成。
            llama_log_set({ _, _, _ in }, nil)
            llama_backend_init()
            Self.backendReady = true
        }

        var modelParams = llama_model_default_params()
        // iOS 上 Metal 后端可用；模拟器没有 Metal，会自动回落 CPU。
        modelParams.n_gpu_layers = config.gpuLayers
        // 权重的读法见 AppSettings.loadMode —— 那里记着为什么这半个 G 只能 mmap。
        // MLOCK 更不行：那是把内存钉死不许回收，iOS 会直接因超限杀掉 app。
        modelParams.load_mode = config.loadMode

        // 把半个 GB 的权重映射进来要几秒，没有进度的话界面看着像卡死。
        // C 回调不能捕获 Swift 闭包，所以把接收方包进一个 class，用 user_data 把指针带过去。
        let reporter = ProgressReporter(onProgress)
        if onProgress != nil {
            modelParams.progress_callback_user_data = Unmanaged.passUnretained(reporter).toOpaque()
            modelParams.progress_callback = { progress, userData in
                guard let userData else { return true }
                Unmanaged<ProgressReporter>.fromOpaque(userData)
                    .takeUnretainedValue()
                    .report(Double(progress))
                // 返回 false 会让 llama.cpp 立刻中止加载。
                return true
            }
        }

        // reporter 必须活过整个加载过程 —— 上面传的是 unretained 指针。
        let loaded = withExtendedLifetime(reporter) {
            llama_model_load_from_file(modelPath, modelParams)
        }
        guard let loadedModel = loaded else {
            throw LlamaError.modelLoadFailed(URL(fileURLWithPath: modelPath).lastPathComponent)
        }
        model = loadedModel
        vocab = llama_model_get_vocab(loadedModel)

        onPreparingContext?()

        // 建上下文这一步会失败，而且是刚装完那几次必然失败、开到第三四次突然就好了。
        //
        // 一度以为是内存或者过热，直到把数字打出来：失败当时空着 2 GB，机器 cool。
        // 两个猜测同时出局。剩下的解释指向这一步里另一件事 —— 首次运行要编译 Metal
        // 内核，编完进系统着色器缓存。「攒够几次就再也不用编」正好对上那个症状。
        //
        // 所以重试的形状跟着改：先按原尺寸多试几次，中间真的等一会儿。原来那版是
        // 立刻缩小尺寸再试，两头都错 —— 不是内存问题，缩小没用；而「立刻」等于没等。
        // 缩小留在最后两档兜底，万一某台机器上真是内存不够。
        let attempts: [(delay: Duration, shrink: UInt32)] = [
            (.zero, 1),
            (.milliseconds(400), 1),
            (.milliseconds(900), 1),
            (.milliseconds(900), 2),
            (.milliseconds(900), 4),
        ]

        var createdContext: OpaquePointer?
        var granted = (contextSize: config.contextSize, batchSize: config.batchSize)

        for attempt in attempts {
            if attempt.delay > .zero {
                // actor 里同步等着。这一步本来就在后台线程上，而且此刻界面正停在
                // 「Preparing the GPU」那句话上 —— 多等一秒没人看得出来，
                // 打不开才是看得出来的。
                Thread.sleep(forTimeInterval: attempt.delay.seconds)
            }

            let size = (
                contextSize: max(512, config.contextSize / attempt.shrink),
                batchSize: max(64, config.batchSize / attempt.shrink)
            )

            var contextParams = llama_context_default_params()
            contextParams.n_ctx = size.contextSize
            contextParams.n_batch = size.batchSize
            contextParams.n_ubatch = size.batchSize
            contextParams.n_threads = config.threadCount
            contextParams.n_threads_batch = config.threadCount

            if let ctx = llama_init_from_model(loadedModel, contextParams) {
                createdContext = ctx
                granted = size
                break
            }
        }

        guard let createdContext else {
            // 趁模型还没释放先记下现场 —— 一旦 free 掉，额度就回弹了，
            // 那时候再读到的不是失败当时的数字。
            let snapshot = Self.memorySnapshot()
            llama_model_free(loadedModel)
            model = nil
            vocab = nil
            throw LlamaError.contextCreationFailed(
                availableMB: snapshot.availableMB,
                thermal: snapshot.thermal
            )
        }
        context = createdContext
        // 后面喂 prompt 要按实际拿到的批大小分块，裁剪历史也要按实际的上下文长度算。
        // 记下真正生效的那一组，而不是当初想要的那一组。
        self.config.contextSize = granted.contextSize
        self.config.batchSize = granted.batchSize

        batch = llama_batch_init(Int32(granted.batchSize), 0, 1)
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
    case contextCreationFailed(availableMB: Int, thermal: String)
    case tokenizationFailed
    case decodeFailed(Int32)
    case contextExhausted
    case promptTooLong(promptTokens: Int, contextSize: Int)

    /// 这些字串只进日志和崩溃报告，不再上界面 —— 界面上出错就是一个惊叹号加一个
    /// 重试箭头。所以这里怎么写都行，按看日志的人最省事来：说清楚是哪一步崩的，
    /// 带上原始错误码。
    var errorDescription: String? {
        switch self {
        case .notLoaded:
            return "The model is not loaded yet."
        case .modelLoadFailed(let name):
            return "Could not load \(name). The install may be damaged."
        case .contextCreationFailed(let availableMB, let thermal):
            // 不替 llama.cpp 断言原因。上一版这里写的是「内存不够」，而真实现场是
            // 空着 2 GB、机器 cool —— 那句话把人往错的方向带了整整一天。
            // 只报两个数字，剩下的留给读的人判断。
            return "Could not prepare the GPU. "
                + "\(availableMB) MB free, device \(thermal). "
                + "This usually clears up on the next launch."
        case .tokenizationFailed:
            return "Tokenization failed."
        case .decodeFailed(let code):
            return "Inference failed (code \(code))."
        case .contextExhausted:
            return "The context is full."
        case .promptTooLong(let promptTokens, let contextSize):
            return "Prompt too long: \(promptTokens) tokens, limit \(contextSize)."
        }
    }
}

private extension Duration {
    var seconds: Double {
        let (whole, attos) = components
        return Double(whole) + Double(attos) * 1e-18
    }
}

extension LlamaBridge {
    /// 失败当时的内存额度和温度。
    ///
    /// `os_proc_available_memory` 报的是这个进程还能再要多少。iOS 给每个 app 的额度
    /// 远小于设备物理内存，而且随系统压力浮动 —— 同一台机器、同一个包，这一分钟能
    /// 加载下一分钟不能，差的就是这个数。
    ///
    /// 热状态一并记：建上下文正好要编 Metal 内核、要 GPU 缓冲，机器烫的时候
    /// 这类请求是最先被拒的一批。
    nonisolated static func memorySnapshot() -> (availableMB: Int, thermal: String) {
        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:  thermal = "cool"
        case .fair:     thermal = "warm"
        case .serious:  thermal = "hot"
        case .critical: thermal = "overheating"
        @unknown default: thermal = "in an unknown thermal state"
        }
        return (Int(os_proc_available_memory() / (1024 * 1024)), thermal)
    }
}

/// 给 llama.cpp 的加载进度回调做中转。
///
/// 它每加载一个 tensor 就回调一次，几百上千次 —— 每次都跳到主线程更新界面纯属浪费，
/// 所以跨过一个百分点才往外报一次。
private final class ProgressReporter {
    private let onProgress: ((Double) -> Void)?
    private var lastReported = -1.0

    init(_ onProgress: ((Double) -> Void)?) {
        self.onProgress = onProgress
    }

    func report(_ progress: Double) {
        guard let onProgress, progress - lastReported >= 0.01 || progress >= 1 else { return }
        lastReported = progress
        onProgress(min(max(progress, 0), 1))
    }
}
