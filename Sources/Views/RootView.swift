import SwiftUI

struct RootView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var modelManager: ModelManager
    @EnvironmentObject private var engine: TranslationEngine

    var body: some View {
        Group {
            if modelManager.state == .ready, let modelURL = modelManager.installedModelURL {
                MainTabView()
                    .task(id: loadTrigger(modelURL)) {
                        await engine.loadModel(at: modelURL, settings: settings)
                    }
            } else {
                // 模型没装好之前整个 app 没法工作，所以安装页是全屏接管而不是一个提示条。
                ModelSetupView()
            }
        }
        .animation(.default, value: modelManager.state)
    }

    /// 模型文件或推理参数任一变化时重新加载 —— `task(id:)` 会自动取消上一次加载。
    private func loadTrigger(_ url: URL) -> String {
        "\(url.path)|\(settings.runtimeSignature)"
    }
}

struct MainTabView: View {
    var body: some View {
        TabView {
            TranslateView()
                .tabItem { Label(String(localized: "翻译"), systemImage: "character.bubble") }

            HistoryView()
                .tabItem { Label(String(localized: "历史"), systemImage: "clock.arrow.circlepath") }

            SettingsView()
                .tabItem { Label(String(localized: "设置"), systemImage: "gearshape") }
        }
    }
}
