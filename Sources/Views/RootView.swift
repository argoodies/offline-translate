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
        case .loadFailed:
            failureScreen(modelURL: modelURL).transition(.opacity)
        case .ready, .generating, .failed:
            // .failed 是单轮生成出错，模型还在 —— 留在文档里，下一段接着写。
            NoteView().transition(.opacity)
        }
    }

    /// 首次启动要把半 GB 权重 mmap 起来，得有几秒。
    /// 进度来自 llama.cpp 的加载回调，不是假动画。
    private var loadingScreen: some View {
        // ignoresSafeArea 要加在 ZStack 上而不是那层底色上。只染底色的话，
        // ZStack 自己仍然被安全区框着，内容居中的是安全区 —— 刘海和 Home 指示条
        // 的 inset 并不对称，看着就是偏的。
        ZStack {
            Palette.canvas
            VStack(spacing: 22) {
                Image("Logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 112, height: 112)

                ProgressView(value: engine.loadProgress)
                    .progressViewStyle(.linear)
                    .tint(Palette.ink)
                    .frame(width: 180)
            }
        }
        .ignoresSafeArea()
    }

    /// 加载失败给条退路。否则只能杀掉 app 重开 —— 而重开多半也是同样的结果。
    ///
    /// 原先这里写着失败原因和一个「Try again」按钮。现在只剩两个图形：一个惊叹号
    /// 说明出事了，一个转圈箭头说明能重来。具体是哪种错误对用户没用 —— 能做的
    /// 只有再试一次，而这一点图标已经说清楚了。
    private func failureScreen(modelURL: URL) -> some View {
        ZStack {
            Palette.canvas
            VStack(spacing: 28) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(Palette.inkSecondary)

                Button {
                    Task { await engine.loadModel(at: modelURL) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Palette.canvas)
                        .frame(width: 56, height: 56)
                        .background(Palette.ink, in: Circle())
                }
                .accessibilityLabel("Try again")
            }
        }
        .ignoresSafeArea()
    }

    /// 只有构建时漏跑 fetch-model.sh 才会走到这里，正常用户看不到。
    /// 没有重试按钮 —— 包本身就是残的，再试一次也变不出模型来。
    private var missingModel: some View {
        ZStack {
            Palette.canvas
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Palette.inkSecondary)
        }
        .ignoresSafeArea()
    }
}
