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

    /// 首次启动要把半 GB 权重读进来，得有几秒。
    /// 进度来自 llama.cpp 的加载回调，不是假动画 —— 会动的只是那道扫光。
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

                LoadingBar(progress: engine.loadProgress)
                    .frame(width: 180, height: 4)
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

/// 加载进度条。
///
/// 换掉系统的 `ProgressView` 是为了那道扫光。llama.cpp 只在读权重时报进度，
/// 之后建上下文那一段完全没有回调 —— 条会一动不动地停在 90%，而静止的进度条
/// 比慢更像死机。扫光跟进度无关，只要还在加载就一直横穿，说明这事还在进行。
///
/// 填充宽度仍然是真实进度，一格没有多给。
private struct LoadingBar: View {
    let progress: Double

    @State private var sweeping = false

    /// 扫光比整条窄不少，太宽就成了整条在闪。
    private static let bandRatio = 0.38
    private static let period = 1.25

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let band = width * Self.bandRatio
            let filled = width * min(max(progress, 0), 1)

            ZStack(alignment: .leading) {
                Capsule().fill(Palette.ink.opacity(0.13))

                // 空轨道那一段的扫光。这里底色是浅灰，只有压深才看得出来 ——
                // 提亮的那道光在浅色上等于没画。
                sweep(Palette.ink.opacity(0.3), band: band, travel: width)

                Capsule()
                    .fill(Palette.ink)
                    // 已填充的部分至少露一点，否则 0% 时什么都看不见。
                    .frame(width: max(filled, 4))
                    // 回调按 1% 一跳，直接改宽度是一格一格地蹦；
                    // 缓动之后是滑过去的，也顺带把跳变的间隙填上了。
                    .animation(.easeOut(duration: 0.45), value: progress)
                    .overlay(alignment: .leading) {
                        // 已填充那一段的扫光。底色是实心黑，反过来要提亮。
                        sweep(Palette.canvas.opacity(0.5), band: band, travel: width)
                    }
                    .clipShape(Capsule())
            }
            // 空轨道那道光要裁在整条里，否则会溢到条外面去。
            .clipShape(Capsule())
        }
        .onAppear {
            withAnimation(.linear(duration: Self.period).repeatForever(autoreverses: false)) {
                sweeping = true
            }
        }
    }

    /// 一道扫光。
    ///
    /// 整条上画两道：空轨道那段压深，已填充那段提亮。两道用同一个 `travel` 和
    /// 同一个 `sweeping`，所以位置严丝合缝 —— 看上去是一道光横穿整条，
    /// 只是越过填充边界时换了个极性。各自被裁在自己那一段里。
    ///
    /// 走的是整条的长度而不是已填充的长度：后者随进度变，动画中途改终点会让光斑
    /// 突然跳一下。多出去的部分裁掉就是了。
    private func sweep(_ color: Color, band: Double, travel: Double) -> some View {
        LinearGradient(
            colors: [.clear, color, .clear],
            startPoint: .leading, endPoint: .trailing
        )
        .frame(width: band)
        .offset(x: sweeping ? travel : -band)
    }
}
