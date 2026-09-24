import SwiftUI

struct TranslateView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var engine: TranslationEngine
    @EnvironmentObject private var history: HistoryStore
    @StateObject private var speech = SpeechReader()

    @AppStorage("sourceLanguageCode") private var sourceCode = ""
    @AppStorage("targetLanguageCode") private var targetCode = TranslationLanguage.defaultPair().target.code

    @State private var inputText = ""
    @State private var detectedLanguage: TranslationLanguage?
    @State private var autoTranslateTask: Task<Void, Never>?
    @State private var showCopiedToast = false
    @FocusState private var inputFocused: Bool

    /// 空字符串代表"自动检测"。
    private var sourceLanguage: TranslationLanguage? {
        TranslationLanguage.language(forCode: sourceCode)
    }

    private var targetLanguage: TranslationLanguage {
        TranslationLanguage.language(forCode: targetCode) ?? .english
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    languageBar
                    inputCard
                    actionRow
                    if !engine.output.isEmpty || engine.isTranslating {
                        outputCard
                    }
                    if case .failed(let message) = engine.phase {
                        errorCard(message)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(String(localized: "翻译"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if engine.phase == .loadingModel {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(String(localized: "加载模型"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if showCopiedToast {
                    toast(String(localized: "已复制"))
                }
            }
        }
        .onChange(of: inputText) { _ in
            detectedLanguage = sourceLanguage == nil ? LanguageDetector.detect(inputText) : nil
            scheduleAutoTranslate()
        }
        .onChange(of: targetCode) { _ in scheduleAutoTranslate() }
        .onChange(of: sourceCode) { _ in
            detectedLanguage = sourceLanguage == nil ? LanguageDetector.detect(inputText) : nil
            scheduleAutoTranslate()
        }
    }

    // MARK: - 语言选择

    private var languageBar: some View {
        HStack(spacing: 8) {
            LanguageMenu(
                title: sourceLabel,
                includeAutoDetect: true,
                selection: Binding(
                    get: { sourceCode },
                    set: { sourceCode = $0 }
                )
            )

            Button(action: swapLanguages) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.bordered)
            .clipShape(Circle())
            // 源语言是"自动"时没有确定的语言可以换过去。
            .disabled(sourceLanguage == nil && detectedLanguage == nil)
            .accessibilityLabel(String(localized: "互换语言"))

            LanguageMenu(
                title: targetLanguage.displayName,
                includeAutoDetect: false,
                selection: Binding(
                    get: { targetCode },
                    set: { targetCode = $0 }
                )
            )
        }
    }

    private var sourceLabel: String {
        if let sourceLanguage {
            return sourceLanguage.displayName
        }
        if let detectedLanguage {
            return String(localized: "自动（\(detectedLanguage.displayName)）")
        }
        return String(localized: "自动检测")
    }

    private func swapLanguages() {
        guard let effectiveSource = sourceLanguage ?? detectedLanguage else { return }
        let newTarget = effectiveSource.code
        sourceCode = targetLanguage.code
        targetCode = newTarget
        // 译文变原文是用户换方向时最想要的结果。
        if !engine.output.isEmpty {
            inputText = engine.output
        }
    }

    // MARK: - 输入

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                if inputText.isEmpty {
                    Text(String(localized: "输入要翻译的文字"))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $inputText)
                    .focused($inputFocused)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 120)
            }
            .padding(8)

            Divider()

            HStack {
                Text("\(inputText.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    if let text = UIPasteboard.general.string {
                        inputText = text
                    }
                } label: {
                    Label(String(localized: "粘贴"), systemImage: "doc.on.clipboard")
                }
                .labelStyle(.iconOnly)
                .disabled(!UIPasteboard.general.hasStrings)

                Button {
                    inputText = ""
                    engine.cancelTranslation()
                } label: {
                    Label(String(localized: "清空"), systemImage: "xmark.circle")
                }
                .labelStyle(.iconOnly)
                .disabled(inputText.isEmpty)
            }
            .font(.subheadline)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - 操作

    private var actionRow: some View {
        HStack(spacing: 12) {
            if engine.isTranslating {
                Button(role: .destructive) {
                    engine.cancelTranslation()
                } label: {
                    Label(String(localized: "停止"), systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            } else {
                Button {
                    inputFocused = false
                    runTranslation()
                } label: {
                    Label(String(localized: "翻译"), systemImage: "arrow.right.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || engine.phase != .ready)
            }
        }
        .controlSize(.large)
    }

    // MARK: - 输出

    private var outputCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(targetLanguage.displayName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if engine.isTranslating {
                    ProgressView().controlSize(.small)
                }
            }

            Text(engine.output.isEmpty ? " " : engine.output)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                // 流式输出时文字不断变长，固定对齐能避免整块内容跳动。
                .animation(nil, value: engine.output)

            if let stats = engine.stats, stats.truncated {
                Label(
                    String(localized: "译文可能被截断，请缩短输入后重试。"),
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            if !engine.output.isEmpty, !engine.isTranslating {
                Divider()
                outputActions
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private var outputActions: some View {
        HStack(spacing: 18) {
            Button {
                UIPasteboard.general.string = engine.output
                showToast()
            } label: {
                Label(String(localized: "复制"), systemImage: "doc.on.doc")
            }

            if SpeechReader.hasVoice(for: targetLanguage) {
                Button {
                    speech.toggle(engine.output, language: targetLanguage)
                } label: {
                    Label(
                        speech.isSpeaking ? String(localized: "停止朗读") : String(localized: "朗读"),
                        systemImage: speech.isSpeaking ? "speaker.slash" : "speaker.wave.2"
                    )
                }
            }

            ShareLink(item: engine.output) {
                Label(String(localized: "分享"), systemImage: "square.and.arrow.up")
            }

            Spacer()

            if let stats = engine.stats {
                Text(String(format: "%.0f tok/s", stats.tokensPerSecond))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .labelStyle(.iconOnly)
        .font(.system(size: 17))
    }

    private func errorCard(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }

    private func toast(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.bottom, 20)
            .transition(.opacity)
    }

    // MARK: - 触发翻译

    private func runTranslation() {
        autoTranslateTask?.cancel()
        let source = sourceLanguage
        let target = targetLanguage
        let input = inputText
        engine.translate(text: input, source: source, target: target, settings: settings) { output in
            guard settings.saveHistory else { return }
            history.add(input: input, output: output, source: source ?? detectedLanguage, target: target)
        }
    }

    /// 输入停顿后自动开译。防抖窗口要够长 —— 每次触发都是一次完整推理，打字中途启动纯属浪费电。
    private func scheduleAutoTranslate() {
        autoTranslateTask?.cancel()
        guard settings.autoTranslate else { return }
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        autoTranslateTask = Task {
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled, engine.phase == .ready else { return }
            runTranslation()
        }
    }

    private func showToast() {
        withAnimation { showCopiedToast = true }
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            withAnimation { showCopiedToast = false }
        }
    }
}

/// 语言下拉菜单。20 个语言用 Menu 比 Picker 的轮盘好按得多。
private struct LanguageMenu: View {
    let title: String
    let includeAutoDetect: Bool
    @Binding var selection: String

    var body: some View {
        Menu {
            if includeAutoDetect {
                Button(String(localized: "自动检测")) { selection = "" }
                Divider()
            }
            ForEach(TranslationLanguage.all) { language in
                Button {
                    selection = language.code
                } label: {
                    // 同时给出本地化名和母语写法，系统语言与目标语言不同时也能认出来。
                    Text(language.displayName == language.endonym
                         ? language.displayName
                         : "\(language.displayName) · \(language.endonym)")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
            .font(.subheadline.weight(.medium))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}
