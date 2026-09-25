import SwiftUI

struct RootView: View {
    @EnvironmentObject private var engine: ChatEngine

    var body: some View {
        Group {
            if let modelURL = BundledModel.url {
                content(modelURL: modelURL)
                    .task { await engine.loadModel(at: modelURL) }
            } else {
                missingModel
            }
        }
        .animation(.easeOut(duration: 0.25), value: engine.phase)
    }

    /// 模型没就绪就不构建对话界面 —— 不是拿遮罩盖住，是根本不存在。
    /// 只有加载成功（或重试成功）才进得去。
    @ViewBuilder
    private func content(modelURL: URL) -> some View {
        switch engine.phase {
        case .loadingModel:
            loadingScreen.transition(.opacity)
        case .loadFailed(let message):
            failureScreen(message, modelURL: modelURL).transition(.opacity)
        case .ready, .generating, .failed:
            // .failed 是单轮生成出错，模型还在 —— 留在对话里，由输入栏上方提示。
            ChatView().transition(.opacity)
        }
    }

    /// 首次启动要把半 GB 权重 mmap 起来，得有几秒。
    /// 进度来自 llama.cpp 的加载回调，不是假动画。
    private var loadingScreen: some View {
        ZStack {
            Palette.canvas.ignoresSafeArea()
            VStack(spacing: 22) {
                // Logo 是张黑色图，深色模式下得反过来才看得见。
                Image("Logo")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 112, height: 112)
                    .foregroundStyle(Palette.ink)

                ProgressView(value: engine.loadProgress)
                    .progressViewStyle(.linear)
                    .tint(Palette.ink)
                    .frame(width: 180)
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
