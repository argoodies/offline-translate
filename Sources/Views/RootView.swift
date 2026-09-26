import SwiftUI

struct RootView: View {
    @EnvironmentObject private var engine: ChatEngine

    /// 这一轮加载是什么时候开始的。进度条按它算，不按 llama.cpp 报的数。
    @State private var loadStartedAt = Date()
    /// 权重读完、开始建上下文的时刻。
    @State private var gpuStartedAt: Date?

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
        // 重试也是一轮新的加载，两个锚点都要重新起算。
        .onChange(of: engine.phase) { phase in
            guard phase == .loadingModel else { return }
            loadStartedAt = Date()
            gpuStartedAt = nil
        }
        .onChange(of: engine.loadStage) { stage in
            if stage == .preparingContext, gpuStartedAt == nil { gpuStartedAt = Date() }
        }
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
    /// 进度条是编排出来的，不是真实进度 —— 理由见 `scriptedProgress`。
    /// 文案倒是如实的：两步各说各的，因为这两步的体感完全不同，
    /// 统称一句「Loading」会让最难熬的那几秒显得像卡死。
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

                TimelineView(.periodic(from: .now, by: 1.0 / 30)) { timeline in
                    LoadingBar(progress: scriptedProgress(at: timeline.date))
                        .frame(width: 180, height: 4)
                }
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

    /// 进度条走的是时间，不是 llama.cpp 报的进度。
    ///
    /// 真实进度看着糟糕，原因不在数字不准，在两段的形状对不上体感：读权重那段
    /// 忽快忽慢，建上下文那段完全没有回调 —— 于是条子先抽搐一阵，再彻底停住。
    /// 停住的进度条比慢更像崩溃。
    ///
    /// 换成按时间匀速爬：读权重一分钟爬到 50%，进入建上下文直接跳到 90%，
    /// 再用十秒挪到 95%。剩下那 5% 留给真正就绪的那一刻 —— 条子永远不会先到头
    /// 再干等，那是最招人烦的一种。
    ///
    /// 代价要认：这是假的。快的机器上条子会比实际慢，慢的机器上会比实际快。
    /// 它诚实的地方只剩一处 —— 走完 95% 那一下是真就绪，不是定时器到点。
    private func scriptedProgress(at now: Date) -> Double {
        switch engine.loadStage {
        case .weights:
            let t = now.timeIntervalSince(loadStartedAt) / Self.weightsRamp
            return 0.5 * min(1, max(0, t))
        case .preparingContext:
            let t = now.timeIntervalSince(gpuStartedAt ?? now) / Self.gpuRamp
            return 0.9 + 0.05 * min(1, max(0, t))
        }
    }

    /// 读权重那段爬到 50% 用的时间。
    private static let weightsRamp: TimeInterval = 60
    /// 建上下文那段从 90% 挪到 95% 用的时间。
    private static let gpuRamp: TimeInterval = 10

    /// 如实写现在在干什么。
    ///
    /// 第一句连模型名一起报出来。这半分钟里读的到底是什么，是这一屏唯一值得说的事 ——
    /// 而且名字取自 `BundledModel`，换了模型文案自己跟着变，不会说谎。
    ///
    /// 「Preparing the GPU」是在分配 KV cache、建计算图，首次启动还要编 Metal 内核。
    /// 没写「Compiling shaders」是因为那只有第一次成立，之后走系统缓存 ——
    /// 每次都那么说就是假话了。
    private var loadingCaption: String {
        switch engine.loadStage {
        case .weights: return "Reading \(BundledModel.displayName) weights"
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
/// 换掉系统的 `ProgressView` 是为了那道扫光 —— 它跟进度无关，只要还在加载就一直
/// 横穿，哪怕填充宽度不动也说明这事还在进行。
///
/// 填充宽度由 `RootView.scriptedProgress` 给，是时间编排出来的，不是真实进度。
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
                    // 0% 就是零宽。一度给过 4pt 的下限，好让扫光有地方可扫；
                    // 后来扫光改成横穿整条，空轨道自己就有动静了，下限只剩下
                    // 「一上来就已经加载了一截」这个假象。
                    .frame(width: filled)
                    // 不加隐式动画：值本身就是 30fps 连续推的，已经够滑；
                    // 再套一层缓动只会让条子恒定落后半秒，而且 50% 跳到 90%
                    // 那一下本来就该是「直接跳」。
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
