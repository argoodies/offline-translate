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
        // 收笔即落字：键盘一收，刚写的那段就定下来。
        // 切换记事和新建都是先清空 draft 再 blur，所以不会在那两处误提交。
        .onChange(of: writing) { isWriting in
            guard !isWriting else { return }
            commit()
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
            .scrollDismissesKeyboard(.interactively)
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

    /// 正在写出来的回答，末尾跟一根呼吸的光标。
    ///
    /// 光标是独立的 View 而不是拼在文本里的字符 —— 字符没法做淡入淡出。
    /// 代价是它只能跟在整个 Markdown 块之后：块级渲染没有办法把一个会动的 View
    /// 塞进富文本流的末尾。回答短的时候它紧贴着文字，长到换行之后会落在行尾右侧。
    ///
    /// 首个 token 到达前 streamingText 是空的，这时画面上只剩这根光标 ——
    /// 正好替掉了原先那个转圈，更像"对方正在写"。
    private var answerInProgress: some View {
        HStack(alignment: .lastTextBaseline, spacing: 3) {
            answerBody(engine.streamingText)
            TypingCursor()
        }
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
        // 「完成」只负责收起键盘，落笔这件事由 blur 本身触发。
        // 留着它是因为空文档时没内容可滑，下滑收键盘那条路走不通。
        ToolbarItemGroup(placement: .keyboard) {
            Spacer()
            Button(L("Done")) { writing = false }
                .font(.body.weight(.semibold))
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

    /// 把刚写的那段定下来，让模型从下一行接着写。
    private func commit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, engine.phase == .ready else { return }
        draft = ""
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

/// 打字光标：一根呼吸的竖线。
private struct TypingCursor: View {
    /// 跟着正文字号走，换了动态字体也不会一根竖线孤零零地长在那儿。
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 19

    @State private var dimmed = false

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Palette.ink)
            .frame(width: 2, height: height)
            // Shape 没有文字基线，靠它自己对齐会浮在半空；按底部往下压一点，
            // 才和同一行的文字坐在一条线上。
            .alignmentGuide(.lastTextBaseline) { $0[.bottom] - 3 }
            .opacity(dimmed ? 0 : 1)
            .animation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true), value: dimmed)
            .onAppear { dimmed = true }
    }
}
