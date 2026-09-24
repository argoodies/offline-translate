import Foundation
import Combine

/// 用户可调的运行参数。改动会立即落盘，其中影响推理的几项会触发模型重新加载。
@MainActor
final class AppSettings: ObservableObject {
    /// 上下文越大越能记住长对话，但 KV cache 会线性吃内存 —— 在旧机型上是被系统杀掉的主因。
    static let contextSizeOptions = [2048, 4096, 8192]
    static let replyLengthOptions = [256, 512, 1024]
    static let maxThreadCount = max(2, ProcessInfo.processInfo.activeProcessorCount)

    @Published var contextSize: Int { didSet { store(contextSize, "contextSize") } }
    @Published var maxReplyTokens: Int { didSet { store(maxReplyTokens, "maxReplyTokens") } }
    @Published var threadCount: Int { didSet { store(threadCount, "threadCount") } }
    @Published var temperature: Double { didSet { store(temperature, "temperature") } }
    @Published var topP: Double { didSet { store(topP, "topP") } }
    @Published var systemPrompt: String { didSet { store(systemPrompt, "systemPrompt") } }
    /// 关闭时会在 prompt 里塞一个空的思考块，让模型跳过推理直接作答 —— 首字快得多。
    @Published var showReasoning: Bool { didSet { store(showReasoning, "showReasoning") } }

    init() {
        let defaults = UserDefaults.standard
        contextSize = defaults.object(forKey: "contextSize") as? Int ?? 4096
        maxReplyTokens = defaults.object(forKey: "maxReplyTokens") as? Int ?? 512
        threadCount = defaults.object(forKey: "threadCount") as? Int ?? Int(LlamaBridge.Config.defaultThreadCount)
        temperature = defaults.object(forKey: "temperature") as? Double ?? 0.7
        topP = defaults.object(forKey: "topP") as? Double ?? 0.9
        systemPrompt = defaults.string(forKey: "systemPrompt") ?? ChatPrompt.defaultSystemPrompt
        showReasoning = defaults.object(forKey: "showReasoning") as? Bool ?? false
    }

    /// 只包含需要重建 llama context 的参数 —— 变了才重新加载模型。
    var runtimeSignature: String {
        "\(contextSize)|\(threadCount)|\(temperature)|\(topP)"
    }

    func resetSystemPrompt() {
        systemPrompt = ChatPrompt.defaultSystemPrompt
    }

    private func store(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }
}
