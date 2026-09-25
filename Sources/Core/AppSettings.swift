import Foundation

/// 运行参数。
///
/// 没有设置界面 —— 这些就是定值。想调的话改这里重新编译，不给用户旋钮：
/// 上下文和线程数调错会让 app 在旧机型上被系统直接结束，不该让人在界面上试错。
enum AppSettings {
    /// 上下文越大越能记住长对话，但 KV cache 会线性吃内存。
    static let contextSize = 4096
    static let maxReplyTokens = 512
    /// 性能核数量；iPhone 上开满所有核反而会被调度器降频，留一个给系统。
    static let threadCount = Int(LlamaBridge.Config.defaultThreadCount)
    static let temperature = 0.7
    static let topP = 0.9
    static let systemPrompt = ChatPrompt.defaultSystemPrompt
}
