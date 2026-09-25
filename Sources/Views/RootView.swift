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

    /// 只有一种情况进不去：模型加载失败。那时整屏是错误页，不是拿遮罩盖住 ——
    /// 对话界面根本不构建，只有重试成功才放行。
    ///
    /// 「加载中」曾经也拦在外面，后来放开了：见下面那段注释。
    @ViewBuilder
    private func content(modelURL: URL) -> some View {
        switch engine.phase {
        case .loadFailed:
            failureScreen(modelURL: modelURL).transition(.opacity)
        case .loadingModel, .ready, .generating, .failed:
            // 加载中也直接进来。进来第一件事是写字，而写字本来就要好几秒 ——
            // 让人盯着进度条等完再开始，是把两段本可以重叠的时间排成了串行。
            // 加载进度改在顶栏画一条细线，写完了模型还没好就先收着，就绪即发。
            //
            // .loadFailed 仍然整屏拦住：那是模型压根没有，放进来只能得到一页
            // 什么都不回应的空白。
            // .failed 是单轮生成出错，模型还在 —— 留在文档里，下一段接着写。
            NoteView().transition(.opacity)
        }
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
struct LoadingBar: View {
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
