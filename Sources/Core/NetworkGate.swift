import Foundation
import Combine
import Network

/// 监听设备当前有没有可用网络。
///
/// iOS 没有公开 API 能查「飞行模式是否开启」—— 能查的只有网络可达性。对 Plai 来说这够了：
/// 开了飞行模式必然断开蜂窝。反过来不成立（关掉 Wi-Fi 和蜂窝也算无网），但那同样满足
/// 「不被打扰」这个真正的目的。
@MainActor
final class NetworkGate: ObservableObject {
    /// 当前还连着什么。关卡页靠它说清楚到底是谁在拦。
    enum Link: Equatable {
        case none
        case wifi
        case cellular
        case wired
    }

    @Published private(set) var link: Link = .none
    /// 第一次回调还没来。启动瞬间状态未知，这时不该急着下判断、闪一下提示页。
    @Published private(set) var hasDetermined = false

    var isOffline: Bool { link == .none }
    /// 离线是进入对话的硬条件，没有例外出口。
    var allowsChat: Bool { isOffline }

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "io.argoodies.plai.networkgate")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let link = Self.classify(path)
            Task { @MainActor in
                guard let self else { return }
                self.link = link
                self.hasDetermined = true
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }

    /// 判断走的是哪条真实通路。
    ///
    /// 不能只看 `path.status` —— 开着飞行模式时 iOS 允许 Wi-Fi 单独留着（而且通常会自动
    /// 重连），这时 status 依然是 `.satisfied`。反过来，只剩 loopback 或某个说不清的虚拟
    /// 接口时 status 也可能是 satisfied，那既不构成打扰，也不该把人锁在门外。
    /// 所以按实际使用的接口类型来判。
    private static func classify(_ path: NWPath) -> Link {
        guard path.status == .satisfied else { return .none }
        if path.usesInterfaceType(.wifi) { return .wifi }
        if path.usesInterfaceType(.cellular) { return .cellular }
        if path.usesInterfaceType(.wiredEthernet) { return .wired }
        return .none
    }
}
