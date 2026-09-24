import Foundation

/// 一个可下载的模型量化档。
///
/// 全部来自同一个 Qwen3.5-0.8B，区别只在量化精度 —— 越大越准，越小越省空间和内存。
struct ModelVariant: Identifiable, Hashable, Codable {
    let id: String
    let quantization: String
    let fileName: String
    let byteCount: Int64
    let repository: String
    let summary: String

    var downloadURL: URL {
        // HuggingFace 的 resolve 端点会 302 到 CDN，URLSession 默认跟随重定向。
        URL(string: "https://huggingface.co/\(repository)/resolve/main/\(fileName)?download=true")!
    }

    var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: byteCount)
    }
}

enum ModelCatalog {
    static let repository = "unsloth/Qwen3.5-0.8B-GGUF"

    /// 推荐档：质量和体积的平衡点，也是首次安装的默认选择。
    static let recommended = ModelVariant(
        id: "Q4_K_M",
        quantization: "Q4_K_M",
        fileName: "Qwen3.5-0.8B-Q4_K_M.gguf",
        byteCount: 532_517_120,
        repository: repository,
        summary: String(localized: "推荐。质量与体积的平衡点，适合绝大多数设备。")
    )

    static let all: [ModelVariant] = [
        ModelVariant(
            id: "IQ4_XS",
            quantization: "IQ4_XS",
            fileName: "Qwen3.5-0.8B-IQ4_XS.gguf",
            byteCount: 492_605_696,
            repository: repository,
            summary: String(localized: "最省空间。质量略低于 Q4_K_M，适合存储紧张的设备。")
        ),
        recommended,
        ModelVariant(
            id: "Q5_K_M",
            quantization: "Q5_K_M",
            fileName: "Qwen3.5-0.8B-Q5_K_M.gguf",
            byteCount: 590_057_728,
            repository: repository,
            summary: String(localized: "更高精度。长句和专有名词的处理更稳。")
        ),
        ModelVariant(
            id: "Q8_0",
            quantization: "Q8_0",
            fileName: "Qwen3.5-0.8B-Q8_0.gguf",
            byteCount: 811_843_840,
            repository: repository,
            summary: String(localized: "近乎无损。占用最大，建议仅在 Pro 机型上使用。")
        ),
    ]

    static func variant(withID id: String) -> ModelVariant? {
        all.first { $0.id == id }
    }
}
