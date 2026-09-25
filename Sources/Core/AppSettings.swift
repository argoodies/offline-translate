import Foundation

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
    /// 一度是 MMAP，以为能按页取用。但 `lazy_mode` 默认的 AUTO 只对超过 4 GiB 的
    /// 单个张量生效，0.8B 里没有 —— 头文件的原话是「always read the whole tensor
    /// up front」。于是整个文件照样要全部落地，mmap 只是把一次顺序读换成了三万多次
    /// 缺页中断，省不下内存，还慢。开了 Metal 之后更是如此：GPU buffer 直接包住这块
    /// 内存，权重必须全部常驻。
    ///
    /// DIRECT_IO 走顺序大块读。同样待实测 —— 换回 MMAP 改这一个值就行。
    static let loadMode = LLAMA_LOAD_MODE_DIRECT_IO
    /// 上下文越大越能记住长对话，但 KV cache 会线性吃内存。
    static let contextSize = 4096
    static let maxReplyTokens = 512
    /// 性能核数量；iPhone 上开满所有核反而会被调度器降频，留一个给系统。
    static let threadCount = Int(LlamaBridge.Config.defaultThreadCount)
    static let temperature = 0.7
    static let topP = 0.9
    static let systemPrompt = ChatPrompt.defaultSystemPrompt
}
