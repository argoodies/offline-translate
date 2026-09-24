import Foundation

/// 按 Qwen 的 ChatML 格式拼 prompt。
///
/// 手写模板而不是调 `llama_chat_apply_template`：后者不是 Jinja 解析器，只认内置的一批
/// 模板名，新模型经常落不到正确分支。Qwen 全系列都是 ChatML，手写反而更可靠，也方便
/// 精确控制思考块的抑制方式。
enum ChatPrompt {
    static let defaultSystemPrompt = "You are a helpful, knowledgeable assistant. Answer in the same language the user writes in. Be concise unless the user asks for detail."

    /// Qwen3.5 是 hybrid thinking 模型：在 assistant 开头塞一个空的思考块，它就会跳过推理
    /// 直接作答。省下的全是首字延迟。
    private static let emptyThinkingBlock = "<think>\n\n</think>\n\n"

    /// 一轮全新对话的开场：system + 第一条用户消息。
    static func opening(systemPrompt: String, userMessage: String, suppressThinking: Bool) -> String {
        var prompt = ""
        let system = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !system.isEmpty {
            prompt += "<|im_start|>system\n\(system)<|im_end|>\n"
        }
        prompt += turn(userMessage: userMessage, suppressThinking: suppressThinking)
        return prompt
    }

    /// 后续轮次。只包含新增部分 —— 前面的历史已经在 KV cache 里了。
    ///
    /// 开头那个 `<|im_end|>` 是在补上一轮：生成停在 EOG 时，那个结束符本身并没有被喂回
    /// KV cache，这里必须补齐，否则模型看到的是一段没有收尾的 assistant 消息。
    static func followUp(userMessage: String, suppressThinking: Bool) -> String {
        "<|im_end|>\n" + turn(userMessage: userMessage, suppressThinking: suppressThinking)
    }

    /// 重建整段对话。上下文被裁剪后需要从头喂一次。
    static func rebuild(
        systemPrompt: String,
        history: [ChatMessage],
        userMessage: String,
        suppressThinking: Bool
    ) -> String {
        var prompt = ""
        let system = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !system.isEmpty {
            prompt += "<|im_start|>system\n\(system)<|im_end|>\n"
        }
        for message in history {
            let role = message.role == .user ? "user" : "assistant"
            // 历史里的思考过程不回灌 —— 它对后续回答没有帮助，只会白占上下文。
            prompt += "<|im_start|>\(role)\n\(message.text)<|im_end|>\n"
        }
        prompt += turn(userMessage: userMessage, suppressThinking: suppressThinking)
        return prompt
    }

    private static func turn(userMessage: String, suppressThinking: Bool) -> String {
        var prompt = "<|im_start|>user\n\(userMessage)<|im_end|>\n<|im_start|>assistant\n"
        if suppressThinking {
            prompt += emptyThinkingBlock
        }
        return prompt
    }
}

/// 流式输出清洗器。
///
/// 模型吐出来的不全是正文：ChatML 的控制符会漏出来，思考块可能出现（哪怕已经抑制过），
/// 而这些标记会被 token 切分成好几段。清洗必须是增量的 —— 边生成边显示 —— 所以状态机
/// 要能跨 token 工作，还得把看着像标记开头的尾巴先扣住。
struct StreamSanitizer {
    private(set) var visibleText = ""
    /// 思考块里的内容，单独攒着，由调用方决定展示还是丢弃。
    private(set) var reasoningText = ""

    private var insideThinking = false
    private var heldBack = ""
    private var hasEmittedVisibleText = false

    private static let markers = ["<think>", "</think>", "<|im_end|>", "<|im_start|>", "<|endoftext|>"]
    private static let longestMarker = markers.map(\.count).max() ?? 0

    /// 吃进一段新生成的文本，吐出可以立即追加到界面上的部分。
    mutating func consume(_ chunk: String) -> String {
        heldBack += chunk
        var visible = ""

        while !heldBack.isEmpty {
            if insideThinking {
                guard let range = heldBack.range(of: "</think>") else {
                    // 思考块还没结束。除了可能跨 token 的尾巴，其余都算推理内容。
                    let keep = min(Self.longestMarker, heldBack.count)
                    let consumed = heldBack.count - keep
                    if consumed > 0 {
                        reasoningText += heldBack.prefix(consumed)
                        heldBack.removeFirst(consumed)
                    }
                    break
                }
                reasoningText += heldBack[heldBack.startIndex..<range.lowerBound]
                heldBack.removeSubrange(heldBack.startIndex..<range.upperBound)
                insideThinking = false
                continue
            }

            guard let hit = nextMarker(in: heldBack) else {
                // 没有完整标记。尾部若可能是某个标记的前缀就扣住，等下一个 token 补齐。
                let safeLength = heldBack.count - partialMarkerSuffixLength(heldBack)
                guard safeLength > 0 else { break }
                visible += heldBack.prefix(safeLength)
                heldBack.removeFirst(safeLength)
                break
            }

            visible += heldBack[heldBack.startIndex..<hit.range.lowerBound]
            heldBack.removeSubrange(heldBack.startIndex..<hit.range.upperBound)
            if hit.marker == "<think>" {
                insideThinking = true
            }
            // 其余标记（im_end 等）直接吞掉。
        }

        return emit(visible)
    }

    /// 生成结束时调用，把扣住的尾巴放出来。
    mutating func finish() -> String {
        defer { heldBack = "" }
        if insideThinking {
            reasoningText += heldBack
            return ""
        }
        return emit(heldBack)
    }

    var trimmedReasoning: String? {
        let text = reasoningText.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private mutating func emit(_ text: String) -> String {
        var text = text
        if !hasEmittedVisibleText {
            // 思考块结束后通常跟着一串空行，第一段正文出现前先把它们吃掉。
            text = String(text.drop(while: { $0.isWhitespace || $0.isNewline }))
            guard !text.isEmpty else { return "" }
            hasEmittedVisibleText = true
        }
        visibleText += text
        return text
    }

    private func nextMarker(in text: String) -> (marker: String, range: Range<String.Index>)? {
        var best: (marker: String, range: Range<String.Index>)?
        for marker in Self.markers {
            guard let range = text.range(of: marker) else { continue }
            if best == nil || range.lowerBound < best!.range.lowerBound {
                best = (marker, range)
            }
        }
        return best
    }

    /// 文本尾部有多少字符可能是某个标记的开头（比如结尾正好是 "<thi"）。
    private func partialMarkerSuffixLength(_ text: String) -> Int {
        let maxCheck = min(Self.longestMarker - 1, text.count)
        guard maxCheck > 0 else { return 0 }
        for length in stride(from: maxCheck, through: 1, by: -1) {
            let suffix = String(text.suffix(length))
            if Self.markers.contains(where: { $0.hasPrefix(suffix) }) {
                return length
            }
        }
        return 0
    }
}
