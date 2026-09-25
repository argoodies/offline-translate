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
                .task { Haptics.prepare() }
        }
    }
}
