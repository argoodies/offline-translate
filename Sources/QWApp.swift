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
                // 白底黑字是这个 app 的设定，不跟随系统深色模式。
                .preferredColorScheme(.light)
        }
    }
}
