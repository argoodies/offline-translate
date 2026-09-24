import SwiftUI
import UIKit

@main
struct AeroApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var settings = AppSettings()
    @StateObject private var modelManager = ModelManager()
    @StateObject private var engine = ChatEngine()
    @StateObject private var store = ChatStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(modelManager)
                .environmentObject(engine)
                .environmentObject(store)
                .onAppear { appDelegate.modelManager = modelManager }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// 由 SwiftUI 在首帧注入。background 下载可能在 app 完全启动前就完成了，
    /// 所以这里做成 didSet 触发转交，而不是假设某个固定顺序。
    var modelManager: ModelManager? {
        didSet { forwardPendingCompletion() }
    }

    private var pendingCompletion: (() -> Void)?

    nonisolated func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            self.pendingCompletion = completionHandler
            self.forwardPendingCompletion()
        }
    }

    private func forwardPendingCompletion() {
        guard let modelManager, let pendingCompletion else { return }
        modelManager.backgroundCompletionHandler = pendingCompletion
        self.pendingCompletion = nil
    }
}
