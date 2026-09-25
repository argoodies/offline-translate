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
    /// 刚落笔。右上角先给个勾作为确认，再让位给生成中的「停止」。
    @State private var justSaved = false

    private let bottomAnchor = "bottom"
    private let composerAnchor = "composer"

    var body: some View {
        NavigationStack {
            document
                .navigationTitle(store.current?.title ?? AppSettings.title)
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
        GeometryReader { geometry in
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

                        // 正文下面留半屏空白。一页纸本来就不会在最后一行戛然而止，
                        // 顺带让短笔记也能滑动，下滑收键盘那条路才始终走得通。
                        //
                        // 这半屏是全文唯一一处点了会收笔的地方。收笔即提交，是个不可撤销
                        // 的动作，不该让人一个手滑就触发 —— 上一版整页都能收笔，写着写着
                        // 碰一下屏幕就发出去了。它在正文下方、光标后面，往那儿点本来就带着
                        // 「写完了」的意思，位置本身就是意图。
                        Color.clear
                            .frame(height: geometry.size.height * 0.5)
                            .contentShape(Rectangle())
                            .onTapGesture { writing.toggle() }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 22)
                    .padding(.top, 20)
                    .background(tapCatcher)
                }
                .background(Palette.canvas)
                .scrollDismissesKeyboard(.interactively)
                // 开始写的时候把下方那半屏留白滑出来，让落笔的位置尽量靠上 ——
                // 否则光标贴着键盘，能看见的正文只剩一两行。
                .onChange(of: writing) { isWriting in
                    guard isWriting else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        proxy.scrollTo(composerAnchor, anchor: .top)
                    }
                }
                .onChange(of: store.currentMessages.count) { _ in scrollToBottom(proxy, animated: true) }
                .onChange(of: engine.streamingText) { _ in scrollToBottom(proxy, animated: false) }
                .onChange(of: store.currentID) { _ in scrollToBottom(proxy, animated: false) }
            }
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
                // 到长度上限被截断了。一个省略号说清楚了「话没说完」，
                // 不用一句英文句子 —— 界面上不放任何一种语言的词。
                Image(systemName: "ellipsis")
                    .font(.caption2)
                    .foregroundStyle(Palette.inkTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu { actions(for: message) }
    }

    /// 正在写出来的回答。
    private var answerInProgress: some View {
        answerBody(engine.streamingText)
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

    /// 接住落在正文上的点击。只负责落笔，不负责收笔 —— 点在已经写好的段落之间
    /// 想接着写，光标落下去就行；正在写的时候点这儿什么也不发生。
    ///
    /// 收笔只有两个入口：正文下方那半屏留白，和右上角那个勾。收笔会把这段发出去，
    /// 是个收不回来的动作，入口越少越好。
    ///
    /// 它铺在正文底下而不是加在 ScrollView 上。加在 ScrollView 上的话输入框本身
    /// 也在这个手势的命中范围里，点进输入框想挪一下光标也会被它接走。
    /// 垫在底下，输入框在它前面，点输入框就由输入框自己处理，手势根本收不到。
    private var tapCatcher: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture {
                guard !writing else { return }
                writing = true
            }
    }

    /// 文档末尾那支笔。空文档时它就在左上角，光标落下去就能写。
    private var composer: some View {
        // 没有占位文案 —— 空白页上就是一根光标，跟备忘录一样。
        TextField("", text: $draft, axis: .vertical)
            .id(composerAnchor)
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
                toolbarIcon("line.3.horizontal")
            }
            .accessibilityLabel("Notes")
        }
        // 新建挪到了列表页那个浮起来的按钮上。这里生成时是「停止」，
        // 正在写且写了东西时是「保存」—— 它干的也是收笔：blur 一发生，那段就落定。
        ToolbarItem(placement: .navigationBarTrailing) {
            if justSaved {
                // 落笔的回执。无论是点勾还是点下方留白落的笔，都先给这个勾，
                // 再让位给「停止」—— 生成其实已经在跑了，只是先把这一下说清楚。
                // 同一个勾，落笔后转浅：深色是「可以按」，浅色是「已经落下了」。
                // 两个状态一样深的话，看不出刚才那下到底有没有生效。
                toolbarIcon("checkmark.circle", tint: Palette.inkTertiary)
                    .transition(.scale.combined(with: .opacity))
            } else if engine.isGenerating {
                Button { engine.stop() } label: {
                    toolbarIcon("stop.circle")
                }
                .accessibilityLabel("Stop")
                .transition(.opacity)
            } else if hasDraft {
                Button { writing = false } label: {
                    toolbarIcon("checkmark.circle")
                }
                .accessibilityLabel("Save")
                .transition(.opacity)
            }
        }
        // 键盘上方不再放「完成」。当初留它是因为空文档没内容可滑、下滑收键盘那条路
        // 走不通；正文下方补了半屏留白之后，任何长度的笔记都能滑动，它就多余了 ——
        // 写了东西按右上角的勾，没写东西往下一滑。
    }

    /// 两个 SF Symbol 的字形高度和光学重心并不一致，直接摆上去会一高一低；
    /// 统一字号再塞进等大的方框，才对得齐。
    ///
    /// 右上角那两个状态用的是 `checkmark.circle` 和 `stop.circle` —— 同一族的
    /// 描边圆形，字重和视觉直径都是 SF Symbols 调好的。原先保存用的是光秃秃的
    /// `checkmark`，跟旁边带圆圈的停止摆在同一个位置上轮流出现，一换就跳一下。
    private func toolbarIcon(_ name: String, tint: Color = Palette.ink) -> some View {
        Image(systemName: name)
            .font(.system(size: 17, weight: .regular))
            // 显式取前景色：AccentColor 是固定的黑，深色模式下会直接糊在黑底上。
            .foregroundStyle(tint)
            .frame(width: 30, height: 30)
            .contentShape(Rectangle())
    }

    /// 长按一段弹出来的操作。只给图形，不给词 —— 朗读、拷贝、分享这三个
    /// 系统图标本身就够认，VoiceOver 那边另有说明（accessibilityLabel 不显示在屏幕上）。
    @ViewBuilder
    private func actions(for message: ChatMessage) -> some View {
        if !message.text.isEmpty {
            let speaking = speech.speakingID == message.id
            Button {
                speech.toggle(messageID: message.id, text: message.text)
            } label: {
                Image(systemName: speaking ? "stop.circle" : "speaker.wave.2")
            }
            .accessibilityLabel(speaking ? "Stop reading" : "Read aloud")

            Button {
                UIPasteboard.general.string = message.text
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .accessibilityLabel("Copy")

            ShareLink(item: message.text) {
                Image(systemName: "square.and.arrow.up")
            }
            .accessibilityLabel("Share")
        }
    }

    // MARK: - 上下文提示

    /// 上下文快满了的提示。原本是一句英文，现在是一根细线 ——
    /// 说的本来就是「还剩多少」这种量，一条渐渐填满的线比一句话更直接，
    /// 也不用挑语言。快满的时候才出现，平时一条常驻进度条只是噪音。
    @ViewBuilder
    private var contextBar: some View {
        if engine.contextUsage > 0.75 {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.inkTertiary.opacity(0.3))
                    Capsule()
                        .fill(engine.didTrimHistory ? Palette.ink : Palette.inkSecondary)
                        .frame(width: geometry.size.width * min(1, engine.contextUsage))
                }
            }
            .frame(height: 2)
            .padding(.horizontal, 22)
            .padding(.bottom, 8)
            .background(Palette.canvas)
            .animation(.easeOut(duration: 0.3), value: engine.contextUsage)
        }
    }

    // MARK: - 动作

    /// 正在写，而且确实写了东西。
    private var hasDraft: Bool {
        writing && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 把刚写的那段定下来，让模型从下一行接着写。
    private func commit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, engine.phase == .ready else { return }
        draft = ""
        speech.stop()
        Haptics.messageSent()
        engine.send(text, store: store)

        // 勾只停留一下。生成同时已经开始，所以这不是等待，只是一句回执。
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { justSaved = true }
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            withAnimation(.easeOut(duration: 0.2)) { justSaved = false }
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
