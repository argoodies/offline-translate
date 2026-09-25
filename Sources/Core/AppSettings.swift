import Foundation
import llama

/// 运行参数。
///
/// 没有设置界面 —— 这些就是定值。想调的话改这里重新编译，不给用户旋钮：
/// 上下文和线程数调错会让 app 在旧机型上被系统直接结束，不该让人在界面上试错。
enum AppSettings {
    /// 界面上唯一一个「词」，而它是产品名，不属于任何语言。
    /// 顶栏标题和还没写字的笔记都显示它。
    static let title = "QW"
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
    /// 这里绕了一圈，结论值得记下来。
    ///
    /// mmap 并不像注释里曾经写的那样「按页取用、常驻远低于文件大小」：`lazy_mode`
    /// 默认的 AUTO 只对单个超过 4 GiB 的张量生效，0.8B 里没有那种张量，所以走的是
    /// 头文件里那条「always read the whole tensor up front」—— 整个文件照样会被读完。
    /// 于是它看起来只是把一次顺序读换成了三万多次缺页中断，白亏。
    ///
    /// 照这个推论换成 DIRECT_IO，结果是加载必然在建上下文那一步失败。差别不在读法，
    /// 在这块内存的性质：mmap 的页是文件背书的，系统随时可以丢掉、要用再读回来；
    /// DIRECT_IO 读出来的是脏内存，一分都退不掉。507 MB 脏内存之上再要 KV cache
    /// 和 Metal 缓冲，iOS 直接不给。
    ///
    /// 所以那三万次缺页中断是这半个 G 能塞进一个 app 的入场费，买不掉。
    /// 真想省启动时间，得从别处下手（更小的量化、更少的 offload 层）。
    static let loadMode = LLAMA_LOAD_MODE_MMAP
    /// 上下文越大越能记住长对话，但 KV cache 会线性吃内存 —— 而这块内存是在
    /// `llama_init_from_model` 里一次性分配好的，进度条走完之后那段等待就有它一份。
    /// 4096 砍到 2048，分配量减半；代价是能记住的轮数也减半。
    static let contextSize = 2048
    static let maxReplyTokens = 512
    /// 单次 decode 提交的最大 token 数。计算图的缓冲按它分配，同样在建上下文那一步，
    /// 所以调小既省内存又省启动时间。
    ///
    /// 512 砍到 256 对出字速度基本没影响 —— 它只决定一次喂多少 prompt，
    /// 而这个 app 的输入是一段笔记，本来就远不到 256。
    static let batchSize: UInt32 = 256
    /// 性能核数量；iPhone 上开满所有核反而会被调度器降频，留一个给系统。
    static let threadCount = Int(LlamaBridge.Config.defaultThreadCount)
    static let temperature = 0.7
    static let topP = 0.9
    static let systemPrompt = ChatPrompt.defaultSystemPrompt
}
