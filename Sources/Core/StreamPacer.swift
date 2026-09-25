import Foundation

/// 把模型的突发输出摊平成匀速显示。
///
/// llama.cpp 的出字节奏并不均匀：prompt 吃完之后会一下子涌出一批，碰上长 token 又顿一下。
/// 原本的做法是按时间片把这段时间攒的字一次性糊到界面上 —— 于是屏幕上是一块一块地跳，
/// 而不是在打字。
///
/// 这里在中间放一个待显示队列，用固定节奏往外放：
/// 积压得多就每次多放几个字，积压得少就一个一个来，节奏始终是稳的。
@MainActor
final class StreamPacer {
    /// 放行节奏。30fps 足够顺滑，又不至于让 Markdown 每秒重新解析六十遍。
    private static let tickInterval = Duration.milliseconds(33)
    /// 追赶窗口：积压的字按这个帧数摊开放完。
    /// 太大跟不上模型，太小又会退化成原来那种一块一块地蹦。
    private static let catchUpFrames = 12
    /// 收尾时的追赶窗口。生成已经结束了，不该让人再等着看完。
    private static let drainFrames = 4

    private var pending = ""
    private var ticker: Task<Void, Never>?
    private var isDraining = false

    private let onEmit: (String) -> Void
    private let onTick: () -> Void

    /// - Parameters:
    ///   - onEmit: 放出一段可以显示的文字。
    ///   - onTick: 每次真的放出了字时调一下，用来打触觉反馈。
    init(onEmit: @escaping (String) -> Void, onTick: @escaping () -> Void) {
        self.onEmit = onEmit
        self.onTick = onTick
    }

    func enqueue(_ text: String) {
        guard !text.isEmpty else { return }
        pending += text
        startTickingIfNeeded()
    }

    /// 生成结束：把剩下的加速放完再返回。
    func finish() async {
        isDraining = true
        startTickingIfNeeded()
        while !pending.isEmpty {
            try? await Task.sleep(for: Self.tickInterval)
        }
        ticker?.cancel()
        ticker = nil
        isDraining = false
    }

    /// 中途取消：剩下的不再放出去。
    func cancel() {
        ticker?.cancel()
        ticker = nil
        pending = ""
        isDraining = false
    }

    private func startTickingIfNeeded() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.tickInterval)
                guard let self, !Task.isCancelled else { return }
                self.tick()
            }
        }
    }

    private func tick() {
        guard !pending.isEmpty else { return }

        let frames = isDraining ? Self.drainFrames : Self.catchUpFrames
        let take = max(1, Int(ceil(Double(pending.count) / Double(frames))))
        let chunk = String(pending.prefix(take))
        pending.removeFirst(chunk.count)

        onEmit(chunk)
        onTick()
    }
}
