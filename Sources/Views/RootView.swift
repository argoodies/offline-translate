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
            // .failed 是单轮生成出错，模型还在 —— 留在文档里，下一段接着写。
            NoteView().transition(.opacity)
        }
    }

    /// 首次启动要把半 GB 权重读进来，得有一阵。
    ///
    /// 进度来自 llama.cpp 的加载回调，不是假动画；文案也不糊弄 —— 两步各说各的，
    /// 因为这两步的体感完全不同：读权重有进度可看，建上下文那一步什么都不动，
    /// 只说「Loading」的话正好在最难熬的那几秒里显得像卡死了。
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

                Text(loadingCaption)
                    .font(.footnote)
                    .foregroundStyle(Palette.inkSecondary)
                    .animation(.easeOut(duration: 0.2), value: loadingCaption)
            }
        }
        // 整屏可敲。等半分钟太无聊了，而一块戳下去有反应的屏幕，至少不像死的。
        // 它什么也不改变 —— 加载不会因此变快，只是有点事做。
        .contentShape(Rectangle())
        .onTapGesture { Haptics.idleTap() }
        .ignoresSafeArea()
    }

    /// 如实写现在在干什么。
    ///
    /// 「Reading weights」就是在从包里读那 507 MB；「Preparing the GPU」是在分配
    /// KV cache、建计算图，首次启动还要编 Metal 内核。没写「Compiling shaders」是
    /// 因为那只有第一次成立，之后走的是系统缓存 —— 每次都那么说就是假话了。
    private var loadingCaption: String {
        switch engine.loadStage {
        case .weights: return "Reading weights"
        case .preparingContext: return "Preparing the GPU"
        }
    }

    /// 加载失败给条退路。否则只能杀掉 app 重开 —— 而重开多半也是同样的结果。
    ///
    /// 把 llama.cpp 报的原话写上。「模型文件坏了」和「内存不够」该做的事不一样，
    /// 一个笼统的惊叹号把这个区别抹平了 —— 而这正好是用户唯一需要知道的东西。
    private func failureScreen(_ message: String, modelURL: URL) -> some View {
        ZStack {
            Palette.canvas
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(Palette.inkSecondary)

                Text("Could not load the model")
                    .font(.headline)
                    .foregroundStyle(Palette.ink)

                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Palette.inkSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 44)

                Button {
                    Task { await engine.loadModel(at: modelURL) }
                } label: {
                    Text("Try again")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Palette.canvas)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 11)
                        .background(Palette.ink, in: Capsule())
                }
                .padding(.top, 8)
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
                    // 就是真实进度，0% 就是零宽。一度给过 4pt 的下限，好让扫光有地方
                    // 可扫；后来扫光改成横穿整条，空轨道自己就有动静了，下限只剩下
                    // 「一上来就已经加载了一截」这个假象。
                    .frame(width: filled)
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
