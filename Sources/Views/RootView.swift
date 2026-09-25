import SwiftUI

struct RootView: View {
    @EnvironmentObject private var engine: ChatEngine

    var body: some View {
        ZStack {
            if let modelURL = BundledModel.url {
                ChatView()
                    .task { await engine.loadModel(at: modelURL) }

                // 模型没就绪之前，对话界面没有意义 —— 整屏盖住，别让人对着一个点不动的输入框。
                if engine.phase == .loadingModel {
                    loadingScreen.transition(.opacity)
                } else if case .failed(let message) = engine.phase {
                    failureScreen(message, modelURL: modelURL).transition(.opacity)
                }
            } else {
                missingModel
            }
        }
        .animation(.easeOut(duration: 0.25), value: engine.phase)
    }

    /// 首次启动要把半 GB 权重 mmap 起来，得有几秒。
    /// 进度来自 llama.cpp 的加载回调，不是假动画。
    private var loadingScreen: some View {
        ZStack {
            Palette.canvas.ignoresSafeArea()
            VStack(spacing: 22) {
                Image("Logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 112, height: 112)

                VStack(spacing: 10) {
                    ProgressView(value: engine.loadProgress)
                        .progressViewStyle(.linear)
                        .tint(Palette.ink)
                        .frame(width: 180)

                    Text(L("Loading model…"))
                        .font(.footnote)
                        .foregroundStyle(Palette.inkSecondary)
                }
            }
        }
    }

    /// 加载失败给条退路。否则只能杀掉 app 重开 —— 而重开多半也是同样的结果。
    private func failureScreen(_ message: String, modelURL: URL) -> some View {
        ZStack {
            Palette.canvas.ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(Palette.inkSecondary)

                Text(L("Could not load the model"))
                    .font(.headline)
                    .foregroundStyle(Palette.ink)

                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Palette.inkSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)

                Button {
                    Task { await engine.loadModel(at: modelURL) }
                } label: {
                    Text(L("Try again"))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Palette.canvas)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 11)
                        .background(Palette.ink, in: Capsule())
                }
                .padding(.top, 4)
            }
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
