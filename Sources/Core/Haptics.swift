import UIKit

/// 触觉反馈。
///
/// 只有带 Taptic Engine 的 iPhone 有效；iPad 上这些调用什么也不会发生，
/// 但不会出错，所以不用分平台判断。
@MainActor
enum Haptics {
    /// 发送消息：一次明确的轻敲。
    private static let send = UIImpactFeedbackGenerator(style: .light)
    /// 生成过程中的细碎反馈。用 soft 而不是 light —— 前者钝得多，
    /// 密集触发时不会变成一串刺耳的敲击。
    private static let stream = UIImpactFeedbackGenerator(style: .soft)

    private static var lastStreamTick = Date.distantPast

    /// 预热。不预热的话第一次触发有几十毫秒延迟，正好错过它要标记的那个瞬间。
    static func prepare() {
        send.prepare()
        stream.prepare()
    }

    static func messageSent() {
        send.impactOccurred()
        // 紧接着就是生成，顺手把另一个也热上。
        stream.prepare()
    }

    /// 模型每放出一段文字敲一下。
    ///
    /// 节奏由 StreamPacer 决定（约 30 次/秒），这里再限一道 45ms 的下限，
    /// 让它落在每秒二十次上下 —— 密到能连成一串"正在打字"的手感，
    /// 又不至于变成一阵分不出颗粒的嗡嗡声。
    static func streamTick() {
        let now = Date()
        guard now.timeIntervalSince(lastStreamTick) >= 0.045 else { return }
        lastStreamTick = now
        stream.impactOccurred(intensity: 0.55)
    }
}
