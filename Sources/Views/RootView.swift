import SwiftUI

struct RootView: View {
    @EnvironmentObject private var engine: ChatEngine

    var body: some View {
        ZStack {
            if let modelURL = BundledModel.url {
                ChatView()
                    .task { await engine.loadModel(at: modelURL) }
            } else {
                missingModel
            }

            if engine.phase == .loadingModel {
                launchScreen
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.25), value: engine.phase)
    }

    /// 首次启动要把半 GB 权重 mmap 起来，有一两秒空窗，不挡一下会看到一个空白的对话界面。
    /// 接着系统那张启动图往下演，所以这里用同一个 logo。
    private var launchScreen: some View {
        ZStack {
            Palette.canvas.ignoresSafeArea()
            Image("Logo")
                .resizable()
                .scaledToFit()
                .frame(width: 128, height: 128)
        }
    }

    /// 只有构建时漏跑 fetch-model.sh 才会走到这里，正常用户看不到。
    private var missingModel: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Palette.inkSecondary)
            Text(L("The model file is missing"))
                .font(.headline)
            Text(L("This build is incomplete. Please reinstall."))
                .font(.subheadline)
                .foregroundStyle(Palette.inkSecondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.canvas)
    }
}
