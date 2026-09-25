import Foundation

/// 把流式输出到一半的 Markdown 补成合法的。
///
/// 不做这件事的话有两种跳变：
///
/// 一是渲染方式切换 —— 生成时用纯文本、结束后换成 Markdown，最后一刻整段重排，
/// 标题突然变大、列表缩进、代码块冒出底色。
///
/// 二是半截语法本身。模型刚吐出一个 ``` 时，后面所有文字都会被当成代码块；
/// 下一帧补上结束符又变回正文。一个 `**` 会让后半段忽粗忽细。
///
/// 所以每一帧都先补齐未闭合的结构，让布局从第一个字符起就是最终形态。
enum MarkdownStabilizer {
    static func stabilized(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        var result = droppingDanglingBlockMarker(text)
        let (body, insideFence) = strippingFencedBlocks(result)

        if insideFence {
            // 代码块里的内容不按 Markdown 解析，补上结束栅栏就够了。
            if !result.hasSuffix("\n") { result += "\n" }
            return result + "```"
        }

        // 长的先补：`**` 里含 `*`，`~~` 里含 `~`，顺序反了会数错。
        for marker in ["~~", "**", "`"] {
            if occurrences(of: marker, in: body).isMultiple(of: 2) { continue }
            result += marker
        }
        return result
    }

    /// 最后一行只有一个刚起头的块级标记时，先别渲染它。
    ///
    /// 模型吐出 `#` 的那一帧，这一行会立刻变成一级标题那么大，下一帧补上文字才恢复正常 ——
    /// 与其让它闪一下，不如等内容到齐。列表符号和引用同理。
    private static func droppingDanglingBlockMarker(_ text: String) -> String {
        guard let lastBreak = text.lastIndex(of: "\n") else {
            return isDanglingMarker(text) ? "" : text
        }
        let lastLine = String(text[text.index(after: lastBreak)...])
        guard isDanglingMarker(lastLine) else { return text }
        return String(text[..<lastBreak])
    }

    private static func isDanglingMarker(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        // 标题、无序列表、引用、有序列表 —— 后面还没跟上任何内容。
        if trimmed.allSatisfy({ $0 == "#" }) { return true }
        if trimmed == "-" || trimmed == "*" || trimmed == "+" || trimmed == ">" { return true }
        if trimmed.hasSuffix("."), trimmed.dropLast().allSatisfy(\.isNumber) { return true }
        return false
    }

    /// 去掉成对的围栏代码块，并报告结尾是否仍停在某个未闭合的块里。
    ///
    /// 计数前必须先剥掉这些块：里面的 `*`、`_`、`` ` `` 是代码的一部分，
    /// 拿去配对只会把正文补出多余的符号。
    private static func strippingFencedBlocks(_ text: String) -> (body: String, insideFence: Bool) {
        var body = ""
        var insideFence = false
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                insideFence.toggle()
                continue
            }
            if !insideFence {
                body += line
                body += "\n"
            }
        }
        return (body, insideFence)
    }

    private static func occurrences(of marker: String, in text: String) -> Int {
        guard !marker.isEmpty else { return 0 }
        return text.components(separatedBy: marker).count - 1
    }
}
