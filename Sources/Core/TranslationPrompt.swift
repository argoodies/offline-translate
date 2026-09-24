import Foundation

/// 译文风格。写进 system prompt，0.8B 这个量级对风格词的响应比对长篇指令好得多。
enum TranslationTone: String, CaseIterable, Identifiable, Codable {
    case natural
    case formal
    case casual

    var id: String { rawValue }

    var label: String {
        switch self {
        case .natural: return String(localized: "自然")
        case .formal: return String(localized: "正式")
        case .casual: return String(localized: "口语")
        }
    }

    var instruction: String {
        switch self {
        case .natural:
            return "Use natural, idiomatic phrasing that a native speaker would actually write."
        case .formal:
            return "Use formal, polite register suitable for business or official documents."
        case .casual:
            return "Use casual, conversational register, as in everyday speech or chat messages."
        }
    }
}

/// 把翻译请求拼成 Qwen 的 ChatML prompt。
///
/// 这里手写模板而不是调 `llama_chat_apply_template`：后者不是 Jinja 解析器，只认内置的一批模板名，
/// 新模型经常落不到正确分支；而且我们需要精确控制 thinking 块的抑制方式。
/// Qwen 全系列的对话格式都是 ChatML，手写是安全的。
enum TranslationPrompt {
    static let assistantOpening = "<|im_start|>assistant\n"
    /// Qwen 的 hybrid thinking 模型：在 assistant 开头塞一个空的思考块，
    /// 模型就会跳过推理直接给答案。翻译任务不需要思考，省下的全是首字延迟。
    static let emptyThinkingBlock = "<think>\n\n</think>\n\n"

    static func build(
        text: String,
        source: TranslationLanguage?,
        target: TranslationLanguage,
        tone: TranslationTone,
        suppressThinking: Bool
    ) -> String {
        var prompt = "<|im_start|>system\n"
        prompt += systemPrompt(source: source, target: target, tone: tone)
        prompt += "<|im_end|>\n"
        prompt += "<|im_start|>user\n"
        prompt += text
        prompt += "<|im_end|>\n"
        prompt += assistantOpening
        if suppressThinking {
            prompt += emptyThinkingBlock
        }
        return prompt
    }

    private static func systemPrompt(
        source: TranslationLanguage?,
        target: TranslationLanguage,
        tone: TranslationTone
    ) -> String {
        let origin = source.map { "from \($0.promptName) " } ?? ""
        return """
        You are a professional translator. Translate the user's message \(origin)into \(target.promptName).

        Rules:
        - Output ONLY the translation. No explanations, no notes, no romanization, no original text.
        - Do not wrap the translation in quotes unless the original text was quoted.
        - Preserve line breaks, lists, numbers, URLs, code and proper nouns.
        - If a segment is already in \(target.promptName), leave it as is.
        - \(tone.instruction)
        """
    }
}

/// 流式清洗器：模型的输出并不总是干净的译文，小模型尤其爱加前缀、包引号、
/// 或者在 thinking 被抑制的情况下仍然吐出 `<think>` 块。
///
/// 清洗必须是增量的（边生成边显示），所以状态机要能跨 token 工作。
struct TranslationSanitizer {
    private var insideThinking = false
    /// 可能是标记开头的半截文本，先扣住不显示，等看清楚了再决定。
    private var heldBack = ""
    private var hasEmittedVisibleText = false
    private var totalEmitted = ""

    private static let markers = ["<think>", "</think>", "<|im_end|>", "<|im_start|>", "<|endoftext|>"]
    private static let longestMarker = markers.map(\.count).max() ?? 0
    /// 模型有时会先写个标签再给译文，这些前缀一律剥掉。
    private static let leadingNoise = [
        "translation:", "translated text:", "译文：", "翻译：", "翻译结果：", "译文:", "翻译:",
    ]

    /// 吃进一段新生成的文本，吐出可以立即显示的部分。
    mutating func consume(_ chunk: String) -> String {
        heldBack += chunk
        var visible = ""

        while !heldBack.isEmpty {
            if insideThinking {
                guard let range = heldBack.range(of: "</think>") else {
                    // 思考块还没结束，只保留可能跨 token 的尾巴，其余直接丢弃。
                    heldBack = String(heldBack.suffix(Self.longestMarker))
                    break
                }
                heldBack.removeSubrange(heldBack.startIndex..<range.upperBound)
                insideThinking = false
                continue
            }

            guard let hit = nextMarker(in: heldBack) else {
                // 没有完整标记。尾部若可能是标记的前缀就扣住，等下一个 token 补齐。
                let safeLength = heldBack.count - partialMarkerSuffixLength(heldBack)
                guard safeLength > 0 else { break }
                visible += String(heldBack.prefix(safeLength))
                heldBack.removeFirst(safeLength)
                break
            }

            visible += String(heldBack[heldBack.startIndex..<hit.range.lowerBound])
            heldBack.removeSubrange(heldBack.startIndex..<hit.range.upperBound)
            if hit.marker == "<think>" {
                insideThinking = true
            }
            // 其余标记（im_end 等）直接吞掉即可。
        }

        return emit(visible)
    }

    /// 生成结束时调用，把扣住的尾巴放出来。
    mutating func finish() -> String {
        defer { heldBack = "" }
        guard !insideThinking else { return "" }
        return emit(heldBack)
    }

    /// 整段译文的最终形态 —— 用于写入历史记录和复制，会修掉首尾的引号/空白。
    var finalText: String {
        var text = totalEmitted.trimmingCharacters(in: .whitespacesAndNewlines)
        // 成对的包裹引号才剥，单边引号可能是原文的一部分。
        let quotePairs: [(Character, Character)] = [("\"", "\""), ("“", "”"), ("「", "」"), ("『", "』")]
        for (open, close) in quotePairs where text.count >= 2 && text.first == open && text.last == close {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        return text
    }

    private mutating func emit(_ text: String) -> String {
        var text = text
        if !hasEmittedVisibleText {
            // 开头的空白和标签前缀在第一段可见文本里剥掉，后面就不用再判断了。
            text = stripLeadingNoise(text)
            guard !text.isEmpty else { return "" }
            hasEmittedVisibleText = true
        }
        totalEmitted += text
        return text
    }

    private func stripLeadingNoise(_ text: String) -> String {
        var result = text
        var changed = true
        while changed {
            changed = false
            result = String(result.drop(while: { $0.isWhitespace || $0.isNewline }))
            let lowered = result.lowercased()
            for prefix in Self.leadingNoise where lowered.hasPrefix(prefix) {
                result.removeFirst(prefix.count)
                changed = true
                break
            }
        }
        return result
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

    /// 文本尾部有多少字符可能是某个标记的开头（如结尾是 "<thi"）。
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
