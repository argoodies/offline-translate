import SwiftUI
import UIKit
import MarkdownUI

struct ChatView: View {
    @EnvironmentObject private var engine: ChatEngine
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var speech: SpeechReader

    @State private var draft = ""
    @State private var showConversations = false
    @FocusState private var inputFocused: Bool

    /// 滚到底部用的锚点。
    private let bottomAnchor = "bottom"

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                messageList
                inputBar
            }
            .navigationTitle(store.current?.title ?? L("New chat"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Palette.canvas, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        showConversations = true
                    } label: {
                        toolbarIcon("sidebar.leading")
                    }
                    .accessibilityLabel(L("Chat list"))
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        startNewConversation()
                    } label: {
                        toolbarIcon("square.and.pencil")
                    }
                    .accessibilityLabel(L("New chat"))
                    .disabled(engine.isGenerating)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                contextBar
            }
            .sheet(isPresented: $showConversations) {
                ConversationListView()
            }
        }
        .onChange(of: store.currentID) { _ in
            // 换会话时上一条还在念就显得很怪。
            speech.stop()
        }
    }

    /// 工具栏图标。
    ///
    /// 两个 SF Symbol 的字形高度和光学重心并不一致，直接摆上去会一高一低；
    /// 统一字号再塞进等大的方框，才对得齐。
    private func toolbarIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 17, weight: .regular))
            .frame(width: 30, height: 30)
            .contentShape(Rectangle())
    }

    // MARK: - 上下文占用

    @ViewBuilder
    private var contextBar: some View {
        // 快满的时候才提示 —— 平时一条常驻进度条只是噪音。
        if engine.contextUsage > 0.75 {
            Text(engine.didTrimHistory
                 ? L("Context was full; earlier messages were dropped")
                 : L("Context is nearly full — consider starting a new chat"))
                .font(.caption2)
                .foregroundStyle(Palette.inkTertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(Palette.canvas)
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
                            message: ChatMessage(role: .assistant, text: engine.streamingText),
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
            .background(Palette.canvas)
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
                .foregroundStyle(Palette.ink)
            Text(L("Entirely offline"))
                .font(.headline)
            Text(L("The model runs on this device. Nothing you say leaves your phone."))
                .font(.subheadline)
                .foregroundStyle(Palette.inkSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
        .padding(.horizontal, 24)
    }

    // MARK: - 输入

    private var inputBar: some View {
        VStack(spacing: 0) {
            // 单轮生成出错：模型还在，对话能接着来，所以只在这里提一句，不接管整屏。
            if case .failed(let message) = engine.phase {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Palette.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Palette.surfaceSunken)
            }

            Divider()

            HStack(alignment: .bottom, spacing: 10) {
                TextField(L("Message…"), text: $draft, axis: .vertical)
                    .focused($inputFocused)
                    .lineLimit(1...5)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Palette.field, in: RoundedRectangle(cornerRadius: 20))

                if engine.isGenerating {
                    Button {
                        engine.stop()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 30))
                            .symbolRenderingMode(.hierarchical)
                    }
                    .accessibilityLabel(L("Stop"))
                } else {
                    Button {
                        send()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 30))
                    }
                    .disabled(!canSend)
                    .accessibilityLabel(L("Send"))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Palette.canvas)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && engine.phase == .ready
    }

    private func send() {
        let text = draft
        draft = ""
        speech.stop()
        Haptics.messageSent()
        engine.send(text, store: store)
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

    private var isSpeaking: Bool { speech.speakingID == message.id }

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
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
                    Label(L("Reply cut off at the length limit"), systemImage: "scissors")
                        .font(.caption2)
                        .foregroundStyle(Palette.inkTertiary)
                }

            }
            .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
            .contextMenu {
                if !message.text.isEmpty {
                    Button {
                        speech.toggle(messageID: message.id, text: message.text)
                    } label: {
                        Label(
                            isSpeaking ? L("Stop reading") : L("Read aloud"),
                            systemImage: isSpeaking ? "stop.circle" : "speaker.wave.2"
                        )
                    }
                    Button {
                        UIPasteboard.general.string = message.text
                    } label: {
                        Label(L("Copy"), systemImage: "doc.on.doc")
                    }
                    ShareLink(item: message.text) {
                        Label(L("Share"), systemImage: "square.and.arrow.up")
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
                .foregroundStyle(Palette.bubbleUserText)
                .clipShape(RoundedRectangle(cornerRadius: 18))
        } else {
            // 全程走 Markdown，包括生成中途 —— 生成时用纯文本、结束后再渲染的话，
            // 最后一刻整段会重排一次。半截语法交给 MarkdownStabilizer 补齐。
            //
            // 文本每次增长都给一点缓动：逐字放行本来就柔和，再把随之而来的
            // 换行、重排也缓一下，整体才是"浮出来"而不是"弹出来"。
            Markdown(MarkdownStabilizer.stabilized(message.text))
                .animation(.easeOut(duration: 0.18), value: message.text)
                .markdownTheme(.qw)
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
            ? AnyShapeStyle(Palette.bubbleUser)
            : AnyShapeStyle(Palette.bubbleAssistant)
    }

}

private extension Theme {
    /// MarkdownUI 的默认主题是给整页文档设计的，字号和段距放进气泡里太松散。
    static let qw = Theme()
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
            .background(Palette.surfaceSunken)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .markdownMargin(top: 6, bottom: 10)
        }
}
