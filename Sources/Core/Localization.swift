import Foundation
import Combine

/// 界面语言。`system` 跟随设备，其余是手动指定。
enum AppLanguage: String, CaseIterable, Identifiable {
    case system = ""
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case japanese = "ja"

    var id: String { rawValue }

    /// 用各自语言的写法列出来 —— 不管当前界面是哪种语言，用户都能认出自己那一行。
    var displayName: String {
        switch self {
        case .system: return L("Match device")
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        case .japanese: return "日本語"
        }
    }
}

/// 当前生效的本地化 bundle。
///
/// iOS 自己的 per-app 语言设置藏在系统设置里，要跳出 app 才能改。这里在 app 内直接切，
/// 做法是把取字符串的 bundle 换成对应的 `.lproj` —— 所有文案都经过 `L(_:)`，
/// 换掉这一个入口就够了。
enum Localization {
    private static let storageKey = "appLanguage"

    private(set) static var bundle: Bundle = resolve(Self.stored)

    static var stored: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .system
    }

    static func apply(_ language: AppLanguage) {
        UserDefaults.standard.set(language.rawValue, forKey: storageKey)
        bundle = resolve(language)
    }

    private static func resolve(_ language: AppLanguage) -> Bundle {
        guard !language.rawValue.isEmpty,
              let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj"),
              let bundle = Bundle(path: path)
        else {
            // 跟随系统，或者请求的语言没打进包里 —— 交回 main，走系统那套匹配规则。
            return .main
        }
        return bundle
    }
}

/// 取一条界面文案。
///
/// 全 app 的文案都走这里而不是直接用 `String(localized:)`：后者锁定 `Bundle.main`，
/// 语言就只能跟着系统走了。
func L(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: Localization.bundle)
}

/// 界面语言的当前选择。改动后整棵视图树会重建，让所有 `L(_:)` 重新求值。
@MainActor
final class LanguageSettings: ObservableObject {
    @Published private(set) var current: AppLanguage = Localization.stored

    func select(_ language: AppLanguage) {
        guard language != current else { return }
        Localization.apply(language)
        current = language
    }
}
