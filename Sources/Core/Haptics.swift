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

    /// 模型每吐出一段文字敲一下。
    ///
    /// 强度压到很低，并且限了最小间隔：生成时每秒要刷新十几二十次，
    /// 照单全收会是一阵持续的嗡嗡声，既烦人又费电。
    static func streamTick() {
        let now = Date()
        guard now.timeIntervalSince(lastStreamTick) >= 0.06 else { return }
        lastStreamTick = now
        stream.impactOccurred(intensity: 0.35)
    }
}
