import Foundation
import NaturalLanguage

/// 一个可翻译的语言。`promptName` 是喂给模型的英文名 —— 小模型对英文语言名的遵循度
/// 明显高于对 BCP-47 代码，所以 prompt 里一律用全称。
struct TranslationLanguage: Identifiable, Hashable, Codable {
    let code: String
    let promptName: String
    /// 该语言自己的写法，用于在选择器里始终可辨认（无论系统语言是什么）。
    let endonym: String

    var id: String { code }

    /// 跟随系统语言的显示名；系统没有对应翻译时回落到 endonym。
    var displayName: String {
        Locale.current.localizedString(forIdentifier: code) ?? endonym
    }

    /// AVSpeechSynthesizer 用的语音标识。
    var speechCode: String { code }
}

extension TranslationLanguage {
    static let simplifiedChinese = TranslationLanguage(code: "zh-Hans", promptName: "Simplified Chinese", endonym: "简体中文")
    static let traditionalChinese = TranslationLanguage(code: "zh-Hant", promptName: "Traditional Chinese", endonym: "繁體中文")
    static let english = TranslationLanguage(code: "en", promptName: "English", endonym: "English")
    static let japanese = TranslationLanguage(code: "ja", promptName: "Japanese", endonym: "日本語")
    static let korean = TranslationLanguage(code: "ko", promptName: "Korean", endonym: "한국어")
    static let french = TranslationLanguage(code: "fr", promptName: "French", endonym: "Français")
    static let german = TranslationLanguage(code: "de", promptName: "German", endonym: "Deutsch")
    static let spanish = TranslationLanguage(code: "es", promptName: "Spanish", endonym: "Español")
    static let portuguese = TranslationLanguage(code: "pt", promptName: "Portuguese", endonym: "Português")
    static let italian = TranslationLanguage(code: "it", promptName: "Italian", endonym: "Italiano")
    static let russian = TranslationLanguage(code: "ru", promptName: "Russian", endonym: "Русский")
    static let arabic = TranslationLanguage(code: "ar", promptName: "Arabic", endonym: "العربية")
    static let hindi = TranslationLanguage(code: "hi", promptName: "Hindi", endonym: "हिन्दी")
    static let thai = TranslationLanguage(code: "th", promptName: "Thai", endonym: "ไทย")
    static let vietnamese = TranslationLanguage(code: "vi", promptName: "Vietnamese", endonym: "Tiếng Việt")
    static let indonesian = TranslationLanguage(code: "id", promptName: "Indonesian", endonym: "Bahasa Indonesia")
    static let turkish = TranslationLanguage(code: "tr", promptName: "Turkish", endonym: "Türkçe")
    static let dutch = TranslationLanguage(code: "nl", promptName: "Dutch", endonym: "Nederlands")
    static let polish = TranslationLanguage(code: "pl", promptName: "Polish", endonym: "Polski")
    static let ukrainian = TranslationLanguage(code: "uk", promptName: "Ukrainian", endonym: "Українська")

    static let all: [TranslationLanguage] = [
        .simplifiedChinese, .traditionalChinese, .english, .japanese, .korean,
        .french, .german, .spanish, .portuguese, .italian, .russian,
        .arabic, .hindi, .thai, .vietnamese, .indonesian, .turkish,
        .dutch, .polish, .ukrainian,
    ]

    static func language(forCode code: String) -> TranslationLanguage? {
        all.first { $0.code == code }
    }

    /// 首次启动时的默认语言对：设备语言 ↔ 英语（设备本就是英语时配简体中文）。
    static func defaultPair() -> (source: TranslationLanguage?, target: TranslationLanguage) {
        let preferred = Locale.preferredLanguages.first.flatMap(matchDeviceLanguage) ?? .english
        return (nil, preferred.code == "en" ? .simplifiedChinese : .english)
    }

    private static func matchDeviceLanguage(_ identifier: String) -> TranslationLanguage? {
        // "zh-Hans-CN" → 先试完整脚本码，再退到主语言码。
        let locale = Locale(identifier: identifier)
        if let script = locale.language.script?.identifier,
           let languageCode = locale.language.languageCode?.identifier,
           let match = language(forCode: "\(languageCode)-\(script)") {
            return match
        }
        guard let languageCode = locale.language.languageCode?.identifier else { return nil }
        return language(forCode: languageCode)
    }
}

/// 离线语种识别。用系统的 NaturalLanguage，不占模型的上下文也不花生成时间。
enum LanguageDetector {
    static func detect(_ text: String) -> TranslationLanguage? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 太短的片段（"ok"、"はい"）识别噪声很大，不如交给模型自己判断。
        guard trimmed.count >= 3 else { return nil }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 3)
        guard let (language, confidence) = hypotheses.max(by: { $0.value < $1.value }),
              confidence >= 0.45 else { return nil }

        // NLLanguage 把中文分成 zh-Hans / zh-Hant，正好和我们的语言码对得上。
        if let match = TranslationLanguage.language(forCode: language.rawValue) {
            return match
        }
        // 其余情况 NLLanguage 给的是纯语言码（"ja"、"fr"）。
        return TranslationLanguage.language(forCode: String(language.rawValue.prefix(2)))
    }
}
