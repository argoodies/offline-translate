import MarkdownUI
import SwiftUI

@main
struct QWApp: App {
    @StateObject private var engine = ChatEngine()
    @StateObject private var store = ChatStore()
    @StateObject private var speech = SpeechReader()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(engine)
                .environmentObject(store)
                .environmentObject(speech)
                // 钉在根上，不是钉在某个视图上。MarkdownUI 默认的 image provider
                // 会用 URLSession 去拉远端图片 —— 模型吐一个 ![](https://…) 就联网了。
                // 放在这里，将来多一处渲染 Markdown 的地方也不会漏掉；
                // 放在调用点上，漏掉是迟早的事。
                .markdownImageProvider(.asset)
                .markdownInlineImageProvider(.asset)
                .task { Haptics.prepare() }
        }
    }
}
