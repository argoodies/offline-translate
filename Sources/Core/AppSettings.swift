import Foundation
import Combine

/// 用户可调的运行参数。改动会立即落盘，其中影响推理的几项会触发模型重新加载。
@MainActor
final class AppSettings: ObservableObject {
    /// 上下文越大越能翻长段落，但 KV cache 会线性吃内存 —— 在旧机型上是被系统杀掉的主因。
    static let contextSizeOptions = [1024, 2048, 4096]

    @Published var contextSize: Int { didSet { store(contextSize, "contextSize") } }
    @Published var threadCount: Int { didSet { store(threadCount, "threadCount") } }
    @Published var temperature: Double { didSet { store(temperature, "temperature") } }
    /// 默认开启：同一句话每次都翻出同样的结果，用户重试时不会以为 app 抽风。
    @Published var deterministicOutput: Bool { didSet { store(deterministicOutput, "deterministicOutput") } }
    @Published var tone: TranslationTone { didSet { store(tone.rawValue, "tone") } }
    @Published var suppressThinking: Bool { didSet { store(suppressThinking, "suppressThinking") } }
    /// 停止输入一小段时间后自动开译，省掉一次点击。
    @Published var autoTranslate: Bool { didSet { store(autoTranslate, "autoTranslate") } }
    @Published var saveHistory: Bool { didSet { store(saveHistory, "saveHistory") } }

    static let maxThreadCount = max(2, ProcessInfo.processInfo.activeProcessorCount)

    init() {
        let defaults = UserDefaults.standard
        contextSize = defaults.object(forKey: "contextSize") as? Int ?? 2048
        threadCount = defaults.object(forKey: "threadCount") as? Int ?? Int(LlamaBridge.Config.defaultThreadCount)
        temperature = defaults.object(forKey: "temperature") as? Double ?? 0.2
        deterministicOutput = defaults.object(forKey: "deterministicOutput") as? Bool ?? true
        tone = (defaults.string(forKey: "tone").flatMap(TranslationTone.init(rawValue:))) ?? .natural
        suppressThinking = defaults.object(forKey: "suppressThinking") as? Bool ?? true
        autoTranslate = defaults.object(forKey: "autoTranslate") as? Bool ?? true
        saveHistory = defaults.object(forKey: "saveHistory") as? Bool ?? true
    }

    /// 只包含需要重建 llama context 的参数 —— 变了才重新加载模型。
    var runtimeSignature: String {
        "\(contextSize)|\(threadCount)|\(deterministicOutput)|\(temperature)"
    }

    private func store(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }
}
