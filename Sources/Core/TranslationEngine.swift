import Foundation
import Combine

/// 串起「加载模型 → 拼 prompt → 流式生成 → 清洗输出」的编排层，也是所有视图的数据源。
@MainActor
final class TranslationEngine: ObservableObject {
    enum Phase: Equatable {
        case needsModel
        case loadingModel
        case ready
        case translating
        case failed(String)

        var isBusy: Bool {
            self == .loadingModel || self == .translating
        }
    }

    struct Stats: Equatable {
        var promptTokens: Int
        var generatedTokens: Int
        /// 从提交到第一个字出现的时间，用户感知最强的指标。
        var firstTokenLatency: TimeInterval
        var tokensPerSecond: Double
        var truncated: Bool
    }

    @Published private(set) var phase: Phase = .needsModel
    @Published private(set) var output = ""
    @Published private(set) var stats: Stats?
    @Published private(set) var modelDescription: String?

    private let bridge = LlamaBridge()
    private var currentTask: Task<Void, Never>?
    private var loadedModelPath: String?
    private var loadedConfigSignature: String?

    var isTranslating: Bool { phase == .translating }

    // MARK: - 模型

    /// 幂等：同一个文件 + 同一套参数重复调用不会重新加载（加载 0.8B 要好几秒）。
    func loadModel(at url: URL, settings: AppSettings) async {
        let signature = settings.runtimeSignature
        if loadedModelPath == url.path, loadedConfigSignature == signature, phase == .ready {
            return
        }

        currentTask?.cancel()
        phase = .loadingModel
        output = ""

        var config = LlamaBridge.Config()
        config.contextSize = UInt32(settings.contextSize)
        config.threadCount = Int32(settings.threadCount)
        // 设置里用 Double（Slider 的原生类型），llama 的采样器要 Float。
        config.temperature = settings.deterministicOutput ? 0 : Float(settings.temperature)

        do {
            try await bridge.load(modelPath: url.path, config: config)
            loadedModelPath = url.path
            loadedConfigSignature = signature
            modelDescription = await bridge.modelInfo()?.description
            phase = .ready
        } catch {
            loadedModelPath = nil
            loadedConfigSignature = nil
            phase = .failed(error.localizedDescription)
        }
    }

    func unloadModel() async {
        currentTask?.cancel()
        currentTask = nil
        await bridge.unload()
        loadedModelPath = nil
        loadedConfigSignature = nil
        modelDescription = nil
        phase = .needsModel
    }

    // MARK: - 翻译

    func translate(
        text: String,
        source: TranslationLanguage?,
        target: TranslationLanguage,
        settings: AppSettings,
        onFinish: @escaping (String) -> Void = { _ in }
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard phase == .ready || phase == .translating else { return }

        currentTask?.cancel()
        output = ""
        stats = nil
        phase = .translating

        let prompt = TranslationPrompt.build(
            text: trimmed,
            source: source,
            target: target,
            tone: settings.tone,
            suppressThinking: settings.suppressThinking
        )
        let budget = tokenBudget(for: trimmed, contextSize: settings.contextSize)

        currentTask = Task { [weak self] in
            await self?.run(prompt: prompt, budget: budget, onFinish: onFinish)
        }
    }

    func cancelTranslation() {
        currentTask?.cancel()
    }

    private func run(prompt: String, budget: Int, onFinish: @escaping (String) -> Void) async {
        var sanitizer = TranslationSanitizer()
        let startedAt = Date()
        var firstTokenAt: Date?
        var generated = 0
        var truncated = false
        // 逐 token 刷新 @Published 会让 SwiftUI 每秒重绘几十次，纯属浪费电；按时间片合并。
        var buffer = ""
        var lastFlush = startedAt

        do {
            let promptTokens = try await bridge.prepare(prompt: prompt, maxNewTokens: budget)

            loop: while true {
                if Task.isCancelled { break }
                let step = try await bridge.step()
                switch step {
                case .token(let piece):
                    generated += 1
                    if firstTokenAt == nil, !piece.isEmpty {
                        firstTokenAt = Date()
                    }
                    buffer += sanitizer.consume(piece)
                    let now = Date()
                    if now.timeIntervalSince(lastFlush) >= 0.05, !buffer.isEmpty {
                        output += buffer
                        buffer = ""
                        lastFlush = now
                    }
                case .endOfGeneration:
                    break loop
                case .contextFull, .tokenLimit:
                    truncated = true
                    break loop
                }
            }

            // 先把 await 的结果落到常量上：在 mutating 方法的参数位置写 await 会撞上独占访问检查。
            let tail = await bridge.drain()
            buffer += sanitizer.consume(tail)
            buffer += sanitizer.finish()
            output += buffer
            output = sanitizer.finalText

            let elapsed = Date().timeIntervalSince(firstTokenAt ?? startedAt)
            stats = Stats(
                promptTokens: promptTokens,
                generatedTokens: generated,
                firstTokenLatency: (firstTokenAt ?? startedAt).timeIntervalSince(startedAt),
                tokensPerSecond: elapsed > 0 ? Double(generated) / elapsed : 0,
                truncated: truncated
            )
            phase = .ready
            if !Task.isCancelled, !output.isEmpty {
                onFinish(output)
            }
        } catch is CancellationError {
            phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// 估算这次翻译最多允许生成多少 token。
    ///
    /// 估得太小会截断长句，估得太大则在模型跑飞（不停复述）时白等好几秒 —— 小模型这种情况不罕见。
    private func tokenBudget(for text: String, contextSize: Int) -> Int {
        // 中日韩大致 1 字 1 token，拉丁文字大致 3~4 字符 1 token。
        let cjkCount = text.unicodeScalars.filter(Self.isCJK).count
        let otherCount = max(0, text.unicodeScalars.count - cjkCount)
        let estimatedInput = cjkCount + otherCount / 3
        // 2.5 倍余量：中译德、中译俄这类组合译文 token 数会显著多于原文。
        let budget = Int(Double(max(estimatedInput, 16)) * 2.5)
        return min(max(budget, 192), max(256, contextSize - estimatedInput - 128))
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF,   // 平假名 / 片假名
             0x3400...0x4DBF,   // 汉字扩展 A
             0x4E00...0x9FFF,   // 汉字基本区
             0xAC00...0xD7AF,   // 谚文音节
             0xF900...0xFAFF:   // 兼容汉字
            return true
        default:
            return false
        }
    }
}
