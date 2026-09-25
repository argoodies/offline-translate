import SwiftUI

@main
struct AeroApp: App {
    @StateObject private var settings = AppSettings()
    @StateObject private var engine = ChatEngine()
    @StateObject private var store = ChatStore()
    @StateObject private var gate = NetworkGate()
    @StateObject private var speech = SpeechReader()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(engine)
                .environmentObject(store)
                .environmentObject(gate)
                .environmentObject(speech)
                // 白底黑字是这个 app 的设定，不跟随系统深色模式。
                .preferredColorScheme(.light)
        }
    }
}
