import SwiftUI

@main
struct AeroApp: App {
    @StateObject private var settings = AppSettings()
    @StateObject private var engine = ChatEngine()
    @StateObject private var store = ChatStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(engine)
                .environmentObject(store)
        }
    }
}
