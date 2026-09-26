import SwiftUI
import UIKit
import MarkdownUI

/// 流式输出末尾那颗跳动的点。
///
/// 它得跟着文字排版走 —— 最后一行短就挨在那一行末尾，换行了就跟到下一行去，
/// 像光标一样。做不到的做法有两种：叠一个 overlay 需要知道「最后一行末尾」的坐标，
/// SwiftUI 不提供；放在 Markdown 下面另起一行，那就成了一个独立的指示器，不是光标。
///
/// 走得通的只有 MarkdownUI 的行内图片：它本来就参与文字排版。代价是行内只能塞
/// `Image`，动不了 —— 所以动画靠逐帧换图，把相位编进 URL 里（`qwcursor://7`），
/// 相位一变内容串就变，Markdown 重新渲染，点就挪了一下。
///
/// 每帧的图预先渲染好缓存着，一共十二张，几百字节。真正的开销是每秒十几次
/// Markdown 重解析 —— 流式输出的时候本来就在以 30fps 重解析（StreamPacer 的节奏），
/// 所以那段时间是白捡的；只有模型卡住不出字的几秒里是额外的。
enum StreamingCursor {
    static let phaseCount = 12
    /// 一轮跳动的时长。跟之前那颗独立的点保持一致。
    static let period: Double = 1.1

    private static let scheme = "qwcursor"
    private static let dotSize: CGFloat = 7
    private static let lift: CGFloat = 5

    /// 按时间算当前相位。
    static func phase(at date: Date) -> Int {
        let t = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period)
        return Int(t / period * Double(phaseCount)) % phaseCount
    }

    /// 接在正文末尾的那一小段 Markdown。
    ///
    /// 不加空格 —— 光标就该贴着最后一个字。`word![](…)` 里的图片语法照样解析。
    static func markdownSuffix(phase: Int) -> String {
        "![](\(scheme)://\(phase))"
    }

    /// 第 n 帧的图。
    ///
    /// 用 template 渲染：颜色交给正文的前景色，深浅色自动跟随，不用自己判。
    /// 渐隐渐现是把 alpha 烘进图里的 —— template 模式拿 alpha 通道当遮罩，所以透明度
    /// 照样生效，只是颜色被替换掉。
    static func image(phase: Int) -> UIImage {
        cache[((phase % phaseCount) + phaseCount) % phaseCount]
    }

    static func isCursor(_ url: URL) -> Bool { url.scheme == scheme }

    private static let cache: [UIImage] = (0..<phaseCount).map { phase in
        // 正弦一上一下：0 在最低点，π/2 在最高点。
        let t = Double(phase) / Double(phaseCount)
        let rise = (sin(t * 2 * .pi - .pi / 2) + 1) / 2   // 0…1
        let alpha = 0.3 + 0.7 * rise

        // 画布留出弹起的高度，否则点一跳就被裁掉，行高也会跟着抖。
        let size = CGSize(width: dotSize, height: dotSize + lift)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            let y = (size.height - dotSize) * (1 - rise)
            let rect = CGRect(x: 0, y: y, width: dotSize, height: dotSize)
            ctx.cgContext.setFillColor(UIColor.black.withAlphaComponent(alpha).cgColor)
            ctx.cgContext.fillEllipse(in: rect)
        }
        return image.withRenderingMode(.alwaysTemplate)
    }
}

/// 只认光标那一个来源的行内图片提供者。
///
/// 模型完全可能吐出 `![](https://…)`。这个 app 不联网，那种链接一律不取 ——
/// 不是懒得实现，是取了就破坏了「一个网络请求都不发」这件事本身。
struct StreamingCursorImageProvider: InlineImageProvider {
    func image(with url: URL, label: String) async throws -> Image {
        guard StreamingCursor.isCursor(url),
              let phase = Int(url.host ?? "")
        else { throw CancellationError() }
        return Image(uiImage: StreamingCursor.image(phase: phase))
    }
}

extension InlineImageProvider where Self == StreamingCursorImageProvider {
    static var streamingCursor: Self { .init() }
}
