import AVFoundation
import Combine
import NaturalLanguage

/// 朗读模型的回复。用系统的 AVSpeechSynthesizer —— 设备上已装的语音包完全离线，
/// 跟这个 app 的其余部分一样不碰网络。
@MainActor
final class SpeechReader: NSObject, ObservableObject {
    /// 正在朗读哪条消息。界面靠它决定按钮显示播放还是停止。
    @Published private(set) var speakingID: UUID?

    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func toggle(messageID: UUID, text: String) {
        if speakingID == messageID {
            stop()
        } else {
            speak(messageID: messageID, text: text)
        }
    }

    func speak(messageID: UUID, text: String) {
        let spoken = Self.plainText(from: text)
        guard !spoken.isEmpty else { return }

        // 换一条就打断上一条，不要两个声音叠在一起。
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        // 用 .playback 而不是默认 category：静音键拨到静音时用户仍然希望听到朗读。
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)

        let utterance = AVSpeechUtterance(string: spoken)
        utterance.voice = Self.voice(for: spoken)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
        speakingID = messageID
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        finish()
    }

    fileprivate func finish() {
        speakingID = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// 按回复本身的语言挑语音 —— 模型会跟着用户的语言走，不能假定是中文。
    private static func voice(for text: String) -> AVSpeechSynthesisVoice? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage else {
            return AVSpeechSynthesisVoice(language: Locale.preferredLanguages.first)
        }
        if let exact = AVSpeechSynthesisVoice(language: language.rawValue) {
            return exact
        }
        // NLLanguage 有时给的是带脚本的码（zh-Hans），系统语音库里不一定有同名的。
        let prefix = String(language.rawValue.prefix(2))
        return AVSpeechSynthesisVoice.speechVoices().first { $0.language.hasPrefix(prefix) }
    }

    /// 把 Markdown 标记去掉再朗读。不处理会听到一堆「井号井号」「星号星号」。
    static func plainText(from markdown: String) -> String {
        var text = markdown

        // 代码块整段跳过 —— 逐字念代码毫无意义。
        text = text.replacingOccurrences(
            of: "```[\\s\\S]*?```", with: " ", options: .regularExpression)
        // 行内代码、加粗、斜体、删除线的包裹符号。
        text = text.replacingOccurrences(of: "`([^`]*)`", with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\*\\*([^*]*)\\*\\*", with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?<!\\*)\\*([^*]+)\\*", with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: "~~([^~]*)~~", with: "$1", options: .regularExpression)
        // 链接留下文字，丢掉 URL。
        text = text.replacingOccurrences(
            of: "\\[([^\\]]*)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
        // 行首的标题井号、引用角括号、列表符号。
        text = text.replacingOccurrences(
            of: "(?m)^\\s{0,3}#{1,6}\\s*", with: "", options: .regularExpression)
        text = text.replacingOccurrences(
            of: "(?m)^\\s{0,3}>\\s*", with: "", options: .regularExpression)
        text = text.replacingOccurrences(
            of: "(?m)^\\s*[-*+]\\s+", with: "", options: .regularExpression)

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension SpeechReader: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.finish()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.finish()
        }
    }
}
