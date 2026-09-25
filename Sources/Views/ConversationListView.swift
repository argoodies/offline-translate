import SwiftUI

/// 所有笔记。
///
/// 这一页上只有「New note」一处文字，其余是图形和数字。
/// 「删除全部」和「重命名」都拿掉了 —— 两者都要弹一个带「取消 / 确定」的对话框。
/// 删除还在，逐条左滑；标题不用改，跟备忘录一样取正文第一行。
struct ConversationListView: View {
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var engine: ChatEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.conversations) { conversation in
                    row(conversation)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Palette.canvas)
            // 新建浮在列表下方 —— 这是这一页最主要的动作，不该藏进右上角的菜单里。
            .safeAreaInset(edge: .bottom) { newNoteButton }
            .navigationTitle(AppSettings.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Palette.canvas, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Palette.ink)
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Close")
                }
            }
        }
    }

    /// 新建。带上文字之后重新用回胶囊 —— 圆形是为了裹住一个孤零零的图标才选的，
    /// 现在里面有内容撑着，胶囊的两头就不空了。
    private var newNoteButton: some View {
        Button {
            select(store.startNewConversation())
        } label: {
            Label("New note", systemImage: "square.and.pencil")
                .font(.body.weight(.medium))
                .foregroundStyle(Palette.canvas)
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .background(Palette.ink, in: Capsule())
        }
        .padding(.bottom, 20)
    }

    private func row(_ conversation: Conversation) -> some View {
        Button {
            select(conversation.id)
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(conversation.title)
                        .font(.body)
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        // 原先是 "2 hours ago" 那种相对时间 —— 好读，但是英文。
                        // 换成纯数字的年月日，哪种语言的人看都一样。
                        Text(conversation.updatedAt, format: Self.stamp)
                        if !conversation.isEmpty {
                            Text("·")
                            Text("\(conversation.messages.count)")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(Palette.inkSecondary)
                }
                Spacer()
                if conversation.id == store.currentID {
                    Image(systemName: "checkmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Palette.ink)
                }
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                store.delete(conversation.id)
                engine.invalidateContext()
            } label: {
                Image(systemName: "trash")
            }
            .accessibilityLabel("Delete")
        }
    }

    /// 只有数字的时间戳。固定 POSIX 区域，免得某些语言下月份变成词。
    private static let stamp = Date.FormatStyle
        .dateTime
        .year()
        .month(.twoDigits)
        .day(.twoDigits)
        .locale(Locale(identifier: "en_US_POSIX"))

    private func select(_ id: UUID) {
        guard !engine.isGenerating else { return }
        store.select(id)
        // KV cache 里存的是上一个会话的历史，换会话必须让它失效。
        engine.invalidateContext()
        dismiss()
    }
}
