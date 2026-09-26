import Foundation
import llama

/// 运行参数。
///
/// 没有设置界面 —— 这些就是定值。想调的话改这里重新编译，不给用户旋钮：
/// 上下文和线程数调错会让 app 在旧机型上被系统直接结束，不该让人在界面上试错。
enum AppSettings {
    /// 界面上唯一一个「词」，而它是产品名，不属于任何语言。
    /// 顶栏标题和还没写字的笔记都显示它。
    ///
    /// 带着感叹号 —— 跟主屏幕图标下面、App Store 上的写法保持一致。
    /// 三处不一样的话，同一个 app 会显得有三个名字。
    static let title = "QW!"
    /// App Store 上的副标题，一字不差。
    ///
    /// 加载走完那两秒会把它显示出来 —— 商店上看到的和装完看到的是同一句，
    /// 中间不掉链子。改这里的话记得同步改 App Store Connect 上的副标题，
    /// 那边改不了代码，这边也读不到那边。
    static let tagline = "Qwen3.5-0.8B on your device"
    /// 交给 Metal 的层数，用来在「启动快」和「出字快」之间取舍。
    ///
    /// 99（全部）启动最慢：全量 offload 会逼着 500 MB 权重在加载时全部落地。
    /// 调小能省下启动时间，但落在 CPU 上的那几层，每个 token 都要重走一遍。
    ///
    /// 这个数字没有实测依据 —— 定它的机器上跑不了 iOS。真机上对比一下再定：
    /// 启动省下的是一次性的，出字慢下来是每个 token 都要还的。
    static let gpuLayers: Int32 = 20
    /// 权重怎么读进来。
    ///
    /// mmap 并不像注释里曾经写的那样「按页取用、常驻远低于文件大小」：`lazy_mode`
    /// 默认的 AUTO 只对单个超过 4 GiB 的张量生效，0.8B 里没有那种张量，走的是
    /// 头文件里那条「always read the whole tensor up front」—— 整个文件照样读完。
    ///
    /// 照这个推论试过 DIRECT_IO。那几版加载确实会失败，但同一批改动里还砍了
    /// contextSize 和 batchSize，而后来发现设备当时是烫的 —— 三个可疑项加一个外部
    /// 条件，谁都没被单独验证过。DIRECT_IO 既不能说有问题，也不能说没问题。
    ///
    /// 留在 mmap 上，因为这是唯一一个确认能用的。要再试 DIRECT_IO 的话单独试，
    /// 而且盯着内存：它读出来的是脏内存，不像 mmap 的页那样能被系统丢掉再读回来。
    static let loadMode = LLAMA_LOAD_MODE_MMAP
    /// 上下文越大越能记住长对话，但 KV cache 会线性吃内存。
    ///
    /// 试过砍到 2048 省启动时间，那段时间加载一直在建上下文那一步失败，一度以为是它。
    /// 后来发现当时手机是烫的 —— 建上下文正好要编 Metal 内核、申请 GPU 缓冲，
    /// 而 iOS 在热压力下就是会拒绝这类请求。所以 2048 到底有没有问题，没有定论。
    ///
    /// 留在 4096 是因为它跑了很久没出过事。想再试 2048 的话，先让设备凉下来。
    static let contextSize = 4096
    static let maxReplyTokens = 512
    /// 单次 decode 提交的最大 token 数，同时也是 `n_ubatch`。
    ///
    /// 和 contextSize 一起砍过一次（512 → 256），那批改动之后加载开始失败，
    /// 于是一并退回 —— 但真凶很可能是设备过热，见上面那段。要再试就一次只动一个，
    /// 而且在凉机上试：上次一口气动了三个（还有 load_mode），出了事谁也摘不清。
    static let batchSize: UInt32 = 512
    /// 性能核数量；iPhone 上开满所有核反而会被调度器降频，留一个给系统。
    static let threadCount = Int(LlamaBridge.Config.defaultThreadCount)
    static let temperature = 0.7
    static let topP = 0.9
    static let systemPrompt = ChatPrompt.defaultSystemPrompt
}
