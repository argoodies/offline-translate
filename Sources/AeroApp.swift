import SwiftUI

@main
struct AeroApp: App {
    @StateObject private var settings = AppSettings()
    @StateObject private var engine = ChatEngine()
    @StateObject private var store = ChatStore()
    @StateObject private var gate = NetworkGate()
    @StateObject private var speech = SpeechReader()
    @StateObject private var language = LanguageSettings()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(engine)
                .environmentObject(store)
                .environmentObject(gate)
                .environmentObject(speech)
                .environmentObject(language)
                // 换语言要让所有 L(_:) 重新求值 —— 换 id 直接重建整棵树，
                // 比给每处文案都挂一个观察者干净。
                .id(language.current)
                // 白底黑字是这个 app 的设定，不跟随系统深色模式。
                .preferredColorScheme(.light)
        }
    }
}
