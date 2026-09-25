import SwiftUI
import UIKit
import MarkdownUI

struct ChatView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var engine: ChatEngine
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var speech: SpeechReader

    @State private var draft = ""
    @State private var showConversations = false
    @State private var showSettings = false
    @FocusState private var inputFocused: Bool

    /// 滚到底部用的锚点。
    private let bottomAnchor = "bottom"

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                messageList
                inputBar
            }
            .navigationTitle(store.current?.title ?? String(localized: "新对话"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        showConversations = true
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                    .accessibilityLabel(String(localized: "对话列表"))
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        startNewConversation()
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel(String(localized: "新对话"))
                    .disabled(engine.isGenerating)

                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel(String(localized: "设置"))
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                contextBar
            }
            .sheet(isPresented: $showConversations) {
                ConversationListView()
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
        }
        .onChange(of: store.currentID) { _ in
            // 换会话时上一条还在念就显得很怪。
            speech.stop()
        }
    }

    // MARK: - 上下文占用

    @ViewBuilder
    private var contextBar: some View {
        // 快满的时候才提示 —— 平时一条常驻进度条只是噪音。
        if engine.contextUsage > 0.75 {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle")
                    Text(engine.didTrimHistory
                         ? String(localized: "上下文已满，较早的对话已被裁剪")
                         : String(localized: "上下文快满了，可以开一个新对话"))
                    Spacer()
                }
                .font(.caption2)
                .foregroundStyle(.orange)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)

                ProgressView(value: engine.contextUsage)
                    .progressViewStyle(.linear)
                    .tint(.orange)
                    .frame(height: 2)
            }
            .background(.bar)
        }
    }

    // MARK: - 消息

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    if store.currentMessages.isEmpty && !engine.isGenerating {
                        emptyState
                    }
                    ForEach(store.currentMessages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                    if engine.isGenerating {
                        MessageBubble(
                            message: ChatMessage(
                                role: .assistant,
                                text: engine.streamingText,
                                reasoning: engine.streamingReasoning
                            ),
                            isStreaming: true
                        )
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(bottomAnchor)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: store.currentMessages.count) { _ in
                scrollToBottom(proxy, animated: true)
            }
            .onChange(of: engine.streamingText) { _ in
                // 流式生成时跟着往下滚，但不加动画 —— 每 50ms 一次的动画会抖得没法看。
                scrollToBottom(proxy, animated: false)
            }
            .onChange(of: store.currentID) { _ in
                scrollToBottom(proxy, animated: false)
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(bottomAnchor, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(bottomAnchor, anchor: .bottom)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "airplane")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tint)
                .rotationEffect(.degrees(-90))
            Text(String(localized: "全程离线"))
                .font(.headline)
            Text(String(localized: "模型跑在这台设备上，对话不会离开你的手机。"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
        .padding(.horizontal, 24)
    }

    // MARK: - 输入

    private var inputBar: some View {
        VStack(spacing: 0) {
            if case .failed(let message) = engine.phase {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }

            Divider()

            HStack(alignment: .bottom, spacing: 10) {
                TextField(String(localized: "发消息…"), text: $draft, axis: .vertical)
                    .focused($inputFocused)
                    .lineLimit(1...5)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))

                if engine.isGenerating {
                    Button {
                        engine.stop()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 30))
                            .symbolRenderingMode(.hierarchical)
                    }
                    .accessibilityLabel(String(localized: "停止"))
                } else {
                    Button {
                        send()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 30))
                    }
                    .disabled(!canSend)
                    .accessibilityLabel(String(localized: "发送"))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && engine.phase == .ready
    }

    private func send() {
        let text = draft
        draft = ""
        speech.stop()
        engine.send(text, store: store, settings: settings)
    }

    private func startNewConversation() {
        speech.stop()
        store.startNewConversation()
        // 新会话的 KV cache 必须从头来，否则模型会带着上一段对话的记忆。
        engine.invalidateContext()
        inputFocused = true
    }
}

/// 一条消息。用户消息靠右、着色；模型回复靠左，按 Markdown 渲染。
private struct MessageBubble: View {
    let message: ChatMessage
    var isStreaming = false

    @EnvironmentObject private var speech: SpeechReader
    @State private var showReasoning = false

    private var isSpeaking: Bool { speech.speakingID == message.id }

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
                if let reasoning = message.reasoning, !reasoning.isEmpty {
                    reasoningBlock(reasoning)
                }

                if !message.text.isEmpty {
                    content
                } else if isStreaming {
                    // 首个 token 到达前给个动静，否则点完发送界面像卡住了。
                    ProgressView()
                        .controlSize(.small)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(bubbleBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                }

                if message.isTruncated {
                    Label(String(localized: "回复因长度上限被截断"), systemImage: "scissors")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }

            }
            .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
            .contextMenu {
                if !message.text.isEmpty {
                    Button {
                        speech.toggle(messageID: message.id, text: message.text)
                    } label: {
                        Label(
                            isSpeaking ? String(localized: "停止朗读") : String(localized: "朗读"),
                            systemImage: isSpeaking ? "stop.circle" : "speaker.wave.2"
                        )
                    }
                    Button {
                        UIPasteboard.general.string = message.text
                    } label: {
                        Label(String(localized: "复制"), systemImage: "doc.on.doc")
                    }
                    ShareLink(item: message.text) {
                        Label(String(localized: "分享"), systemImage: "square.and.arrow.up")
                    }
                }
            }

            if message.role == .assistant { Spacer(minLength: 40) }
        }
    }

    @ViewBuilder
    private var content: some View {
        if message.role == .user {
            // 用户自己打的字原样显示，不做 Markdown 解析 —— 谁也不希望自己打的 * 号消失。
            Text(message.text)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(bubbleBackground)
                .foregroundStyle(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 18))
        } else if isStreaming {
            // 生成过程中用纯文本：半截的 Markdown（没闭合的代码块、写了一半的表格）
            // 每 50 毫秒重新解析一次，界面会疯狂闪烁。生成完再渲染。
            Text(message.text)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(bubbleBackground)
                .clipShape(RoundedRectangle(cornerRadius: 18))
        } else {
            Markdown(message.text)
                .markdownTheme(.aero)
                // 本地模型不会产出图片链接，而且这个 app 不联网 —— 换成只读 asset 的
                // provider，彻底堵死 MarkdownUI 默认的远程图片加载。
                .markdownImageProvider(.asset)
                .markdownInlineImageProvider(.asset)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(bubbleBackground)
                .clipShape(RoundedRectangle(cornerRadius: 18))
        }
    }

    private var bubbleBackground: some ShapeStyle {
        message.role == .user
            ? AnyShapeStyle(Color.accentColor)
            : AnyShapeStyle(Color(.secondarySystemBackground))
    }

    private func reasoningBlock(_ reasoning: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showReasoning.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "brain")
                    Text(String(localized: "思考过程"))
                    Image(systemName: showReasoning ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            if showReasoning {
                Text(reasoning)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }
}

private extension Theme {
    /// MarkdownUI 的默认主题是给整页文档设计的，字号和段距放进气泡里太松散。
    static let aero = Theme()
        .text {
            FontSize(UIFont.preferredFont(forTextStyle: .body).pointSize)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.88))
        }
        .paragraph { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.18))
                .markdownMargin(top: 0, bottom: 10)
        }
        .listItem { configuration in
            configuration.label.markdownMargin(top: 4)
        }
        .codeBlock { configuration in
            ScrollView(.horizontal) {
                configuration.label
                    .relativeLineSpacing(.em(0.2))
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(.em(0.85))
                    }
                    .padding(12)
            }
            .background(Color(.tertiarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .markdownMargin(top: 6, bottom: 10)
        }
}
