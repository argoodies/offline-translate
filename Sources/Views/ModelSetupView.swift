import SwiftUI

/// 首次启动（或模型被删掉后）的安装页。
///
/// 模型不随 app 打包：半 GB 会让安装包大到触发 App Store 的蜂窝下载限制，而且用户换档位时
/// 还得整包更新。代价是首次使用需要联网一次 —— 装完之后就是真正的全程离线了。
struct ModelSetupView: View {
    @EnvironmentObject private var modelManager: ModelManager

    @State private var selectedVariant = ModelCatalog.recommended
    @State private var showAdvanced = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    header
                    switch modelManager.state {
                    case .missing, .failed:
                        variantPicker
                        if case .failed(let message) = modelManager.state {
                            Label(message, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        downloadButton
                    case .downloading(let written, let total), .paused(let written, let total):
                        progressSection(written: written, total: total)
                    case .verifying:
                        ProgressView(String(localized: "正在校验…"))
                            .padding(.vertical, 40)
                    case .ready:
                        ProgressView().padding(.vertical, 40)
                    }
                    footnote
                }
                .padding(24)
            }
            .navigationTitle(String(localized: "准备离线模型"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.dotted")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.tint)
                .padding(.top, 16)

            Text(String(localized: "下载一次，之后永久离线"))
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)

            Text(String(localized: "翻译全部在这台设备上完成，文字不会离开你的手机。你需要先下载一次 Qwen3.5-0.8B 模型权重。"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var variantPicker: some View {
        VStack(spacing: 10) {
            if showAdvanced {
                ForEach(ModelCatalog.all) { variant in
                    variantRow(variant)
                }
            } else {
                variantRow(ModelCatalog.recommended)
                Button(String(localized: "选择其他精度")) {
                    withAnimation { showAdvanced = true }
                }
                .font(.footnote)
            }
        }
    }

    private func variantRow(_ variant: ModelVariant) -> some View {
        Button {
            selectedVariant = variant
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selectedVariant == variant ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(selectedVariant == variant ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(variant.quantization)
                            .font(.subheadline.weight(.semibold).monospaced())
                        Spacer()
                        Text(variant.formattedSize)
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text(variant.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private var downloadButton: some View {
        VStack(spacing: 8) {
            Button {
                modelManager.download(selectedVariant)
            } label: {
                Label(String(localized: "下载模型"), systemImage: "arrow.down.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!hasEnoughSpace)

            if !hasEnoughSpace {
                Text(String(localized: "可用空间不足，请先清理出至少 \(selectedVariant.formattedSize)。"))
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                Text(String(localized: "建议在 Wi-Fi 下下载。切到后台也会继续。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 除了模型本身，还要留出余量给系统和 app 自身运行，所以多要 200MB。
    private var hasEnoughSpace: Bool {
        guard let available = ModelManager.availableCapacity else { return true }
        return available > selectedVariant.byteCount + 200_000_000
    }

    private func progressSection(written: Int64, total: Int64) -> some View {
        var isPaused = false
        if case .paused = modelManager.state { isPaused = true }
        let fraction = total > 0 ? Double(written) / Double(total) : 0

        return VStack(spacing: 16) {
            ProgressView(value: fraction)
                .progressViewStyle(.linear)

            HStack {
                Text(Self.byteFormatter.string(fromByteCount: written))
                Text("/")
                Text(Self.byteFormatter.string(fromByteCount: total))
                Spacer()
                Text(String(format: "%.0f%%", fraction * 100))
            }
            .font(.footnote.monospacedDigit())
            .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button {
                    isPaused ? modelManager.resume() : modelManager.pause()
                } label: {
                    Label(
                        isPaused ? String(localized: "继续") : String(localized: "暂停"),
                        systemImage: isPaused ? "play.fill" : "pause.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button(role: .destructive) {
                    modelManager.cancel()
                } label: {
                    Label(String(localized: "取消"), systemImage: "xmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
        }
    }

    private var footnote: some View {
        VStack(spacing: 6) {
            Text(String(localized: "模型：Qwen3.5-0.8B · Apache-2.0"))
            Text(String(localized: "下载源：Hugging Face"))
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter
    }()
}
