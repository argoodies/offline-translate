import SwiftUI
import UIKit
import MarkdownUI

/// 一整页文档，而不是一串聊天气泡。
///
/// 所有内容 —— 自己写的和模型回的 —— 都在同一条文档流里，从左上往下排，没有气泡、
/// 没有左右分边。输入框就嵌在文档末尾：点屏幕任意处光标就落在那儿，写完收起键盘，
/// 文字原地定格成一段，模型的回答接着在下一行写出来。
///
/// 两者只靠字重区分：自己写的略重，模型回的是常规正文。
struct NoteView: View {
    @EnvironmentObject private var engine: ChatEngine
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var speech: SpeechReader

    @State private var draft = ""
    @State private var showConversations = false
    @FocusState private var writing: Bool

    private let bottomAnchor = "bottom"

    var body: some View {
        NavigationStack {
            document
                .navigationTitle(store.current?.title ?? L("New note"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(Palette.canvas, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbar { toolbarContent }
                .safeAreaInset(edge: .top, spacing: 0) { contextBar }
                .sheet(isPresented: $showConversations) { ConversationListView() }
        }
        .onChange(of: store.currentID) { _ in
            speech.stop()
            draft = ""
            writing = false
        }
    }

    // MARK: - 文档

    private var document: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(store.currentMessages) { message in
                        paragraph(message).id(message.id)
                    }

                    if engine.isGenerating {
                        answerInProgress
                    } else {
                        composer
                    }

                    Color.clear.frame(height: 1).id(bottomAnchor)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.top, 20)
                .padding(.bottom, 32)
            }
            .background(Palette.canvas)
            // 点空白处就开始写 —— 跟备忘录一样，不用去够某个输入框。
            .contentShape(Rectangle())
            .onTapGesture { writing = true }
            .onChange(of: store.currentMessages.count) { _ in scrollToBottom(proxy, animated: true) }
            .onChange(of: engine.streamingText) { _ in scrollToBottom(proxy, animated: false) }
            .onChange(of: store.currentID) { _ in scrollToBottom(proxy, animated: false) }
        }
    }

    /// 已经定稿的一段。
    @ViewBuilder
    private func paragraph(_ message: ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if message.role == .user {
                // 自己打的字原样显示，不做 Markdown 解析 —— 谁也不希望自己写的 * 号消失。
                Text(message.text)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                    .textSelection(.enabled)
            } else {
                answerBody(message.text)
            }

            if message.isTruncated {
                Text(L("Reply cut off at the length limit"))
                    .font(.caption2)
                    .foregroundStyle(Palette.inkTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu { actions(for: message) }
    }

    /// 正在写出来的回答。光标直接跟在文字末尾，像有人在敲。
    private var answerInProgress: some View {
        answerBody(engine.streamingText + "▌")
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 模型回答的正文。
    ///
    /// 全程走 Markdown，包括生成中途 —— 生成时用纯文本、结束后再渲染的话，最后一刻
    /// 整段会重排一次。半截语法交给 MarkdownStabilizer 补齐。
    private func answerBody(_ text: String) -> some View {
        Markdown(MarkdownStabilizer.stabilized(text))
            .markdownTheme(.note)
            // 本地模型不会产出图片链接，而且这个 app 不联网 —— 换成只读 asset 的
            // provider，彻底堵死 MarkdownUI 默认的远程图片加载。
            .markdownImageProvider(.asset)
            .markdownInlineImageProvider(.asset)
            .textSelection(.enabled)
            // 逐字放行本来就柔和，再把随之而来的换行、重排缓一下，
            // 整体才是"浮出来"而不是"弹出来"。
            .animation(.easeOut(duration: 0.18), value: text)
    }

    /// 文档末尾那支笔。空文档时它就在左上角，光标落下去就能写。
    private var composer: some View {
        TextField(store.currentMessages.isEmpty ? L("Start writing…") : "", text: $draft, axis: .vertical)
            .font(.body.weight(.semibold))
            .foregroundStyle(Palette.ink)
            .tint(Palette.ink)
            .textFieldStyle(.plain)
            .focused($writing)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button { showConversations = true } label: {
                toolbarIcon("sidebar.leading")
            }
            .accessibilityLabel(L("Notes"))
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            if engine.isGenerating {
                Button { engine.stop() } label: {
                    toolbarIcon("stop.circle")
                }
                .accessibilityLabel(L("Stop"))
            } else {
                Button { startNewNote() } label: {
                    toolbarIcon("square.and.pencil")
                }
                .accessibilityLabel(L("New note"))
            }
        }
        // 提交动作放在键盘上方 —— 文档里不该常驻一个发送按钮。
        ToolbarItemGroup(placement: .keyboard) {
            Spacer()
            Button(L("Send")) { send() }
                .font(.body.weight(.semibold))
                .disabled(!canSend)
        }
    }

    /// 两个 SF Symbol 的字形高度和光学重心并不一致，直接摆上去会一高一低；
    /// 统一字号再塞进等大的方框，才对得齐。
    private func toolbarIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 17, weight: .regular))
            .frame(width: 30, height: 30)
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private func actions(for message: ChatMessage) -> some View {
        if !message.text.isEmpty {
            Button {
                speech.toggle(messageID: message.id, text: message.text)
            } label: {
                Label(
                    speech.speakingID == message.id ? L("Stop reading") : L("Read aloud"),
                    systemImage: speech.speakingID == message.id ? "stop.circle" : "speaker.wave.2"
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

    // MARK: - 上下文提示

    @ViewBuilder
    private var contextBar: some View {
        // 快满的时候才提示 —— 平时一条常驻进度条只是噪音。
        if engine.contextUsage > 0.75 {
            Text(engine.didTrimHistory
                 ? L("Context was full; earlier messages were dropped")
                 : L("Context is nearly full — consider starting a new note"))
                .font(.caption2)
                .foregroundStyle(Palette.inkTertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(Palette.canvas)
        }
    }

    // MARK: - 动作

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && engine.phase == .ready
    }

    private func send() {
        guard canSend else { return }
        let text = draft
        draft = ""
        // 写完就收笔：键盘退下去，刚写的那段落定，回答从下一行开始。
        writing = false
        speech.stop()
        Haptics.messageSent()
        engine.send(text, store: store)
    }

    private func startNewNote() {
        speech.stop()
        draft = ""
        writing = false
        store.startNewConversation()
        // 新会话的 KV cache 必须从头来，否则模型会带着上一段对话的记忆。
        engine.invalidateContext()
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
}

private extension Theme {
    /// 按正文文档排版，不是气泡里的短消息：行距松一点，段距给足。
    static let note = Theme()
        .text {
            FontSize(UIFont.preferredFont(forTextStyle: .body).pointSize)
            ForegroundColor(Palette.ink)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.88))
        }
        .paragraph { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.22))
                .markdownMargin(top: 0, bottom: 12)
        }
        .listItem { configuration in
            configuration.label.markdownMargin(top: 5)
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
            .markdownMargin(top: 6, bottom: 12)
        }
}
