import Foundation
import Combine
import Network

/// 监听设备当前有没有可用网络。
///
/// iOS 没有公开 API 能查「飞行模式是否开启」—— 能查的只有网络可达性。对 Aero 来说这够了：
/// 开了飞行模式必然无网。反过来不成立（关掉 Wi-Fi 和蜂窝也算无网），但那同样满足
/// 「不被打扰」这个真正的目的。
@MainActor
final class NetworkGate: ObservableObject {
    /// 当前没有任何可用网络路径。
    @Published private(set) var isOffline = false
    /// 第一次回调还没来。启动瞬间状态未知，这时不该急着下判断、闪一下提示页。
    @Published private(set) var hasDetermined = false
    /// 用户在提示页选择了「仍要继续」。
    @Published var userBypassed = false

    var allowsChat: Bool { isOffline || userBypassed }

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "io.argoodies.aero.networkgate")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let offline = path.status != .satisfied
            Task { @MainActor in
                guard let self else { return }
                self.isOffline = offline
                self.hasDetermined = true
                // 一旦真的断网，之前的「仍要继续」就没有意义了，收回来。
                // 这样用户下次联网时还会再被拦一次。
                if offline { self.userBypassed = false }
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}
