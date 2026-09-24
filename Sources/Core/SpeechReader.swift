import AVFoundation
import Combine

/// 朗读译文。用系统的 AVSpeechSynthesizer —— 设备上已装的语音包完全离线，
/// 没装的语言会自动静默失败，所以朗读按钮只在确实有语音时才显示。
@MainActor
final class SpeechReader: NSObject, ObservableObject {
    @Published private(set) var isSpeaking = false

    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func toggle(_ text: String, language: TranslationLanguage) {
        if isSpeaking {
            stop()
            return
        }
        speak(text, language: language)
    }

    func speak(_ text: String, language: TranslationLanguage) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let voice = Self.voice(for: language) else { return }

        // 用 .playback 而不是默认 category：静音键拨到静音时用户仍然希望听到朗读。
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)

        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
        isSpeaking = true
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    static func hasVoice(for language: TranslationLanguage) -> Bool {
        voice(for: language) != nil
    }

    private static func voice(for language: TranslationLanguage) -> AVSpeechSynthesisVoice? {
        if let exact = AVSpeechSynthesisVoice(language: language.speechCode) {
            return exact
        }
        // "zh-Hans" 这类带脚本的码系统语音库里不一定有，回落到同主语言的任意一个。
        let prefix = String(language.code.prefix(2))
        return AVSpeechSynthesisVoice.speechVoices().first { $0.language.hasPrefix(prefix) }
    }
}

extension SpeechReader: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            isSpeaking = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            isSpeaking = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}
