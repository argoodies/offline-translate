import Foundation

/// 随 app 一起打包的模型权重。
///
/// 权重直接进 bundle，不再首次启动下载：装完就能用，没有等待、没有下载失败、
/// 没有「装了 app 却用不了」的中间状态，也不需要任何网络权限。
/// 代价是安装包变成 500 MB 出头 —— 在蜂窝网络下 App Store 会多问用户一次。
///
/// 文件本身不在仓库里（GitHub 单文件上限 100 MB），由 scripts/fetch-model.sh 在构建前拉取。
enum BundledModel {
    static let resourceName = "Qwen3.5-0.8B-Q4_K_M"
    static let resourceExtension = "gguf"

    static let displayName = "Qwen3.5-0.8B"
    static let quantization = "Q4_K_M"

    /// 打包进去的权重文件。理论上不会是 nil —— 真为 nil 说明构建时漏跑了 fetch-model.sh。
    static var url: URL? {
        Bundle.main.url(forResource: resourceName, withExtension: resourceExtension)
    }

    static var formattedSize: String? {
        guard let url,
              let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64
        else { return nil }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }
}
