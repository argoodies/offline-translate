import SwiftUI

struct RootView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var engine: ChatEngine
    @EnvironmentObject private var gate: NetworkGate

    var body: some View {
        ZStack {
            if let modelURL = BundledModel.url {
                ChatView()
                    .task(id: settings.runtimeSignature) {
                        await engine.loadModel(at: modelURL, settings: settings)
                    }
            } else {
                missingModel
            }

            // 模型在后台照常加载 —— 用户开飞行模式的这几秒正好用来 mmap 权重，
            // 等他从控制中心回来通常已经能直接说话了。
            if gate.hasDetermined && !gate.allowsChat {
                AirplaneGateView()
                    .transition(.opacity)
            } else if !gate.hasDetermined || engine.phase == .loadingModel {
                launchScreen
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.25), value: engine.phase)
        .animation(.easeOut(duration: 0.25), value: gate.allowsChat)
        .animation(.easeOut(duration: 0.25), value: gate.hasDetermined)
    }

    /// 首次启动要把半 GB 权重 mmap 起来，有一两秒空窗，不挡一下会看到一个空白的对话界面。
    private var launchScreen: some View {
        ZStack {
            Palette.canvas.ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "airplane")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(Palette.ink)
                    .rotationEffect(.degrees(-90))
                Text(String(localized: "正在加载模型…"))
                    .font(.subheadline)
                    .foregroundStyle(Palette.inkSecondary)
            }
        }
    }

    /// 只有构建时漏跑 fetch-model.sh 才会走到这里，正常用户看不到。
    private var missingModel: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Palette.inkSecondary)
            Text(String(localized: "安装包里缺少模型文件"))
                .font(.headline)
            Text(String(localized: "这个构建不完整，请重新安装。"))
                .font(.subheadline)
                .foregroundStyle(Palette.inkSecondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.canvas)
    }
}
