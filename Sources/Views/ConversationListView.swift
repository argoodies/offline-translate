import SwiftUI

struct ConversationListView: View {
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var engine: ChatEngine
    @Environment(\.dismiss) private var dismiss

    @State private var renamingID: UUID?
    @State private var renameText = ""
    @State private var showDeleteAllConfirmation = false

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
            .navigationTitle(String(localized: "对话"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Palette.canvas, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(String(localized: "关闭")) { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            select(store.startNewConversation())
                        } label: {
                            Label(String(localized: "新对话"), systemImage: "square.and.pencil")
                        }
                        Button(role: .destructive) {
                            showDeleteAllConfirmation = true
                        } label: {
                            Label(String(localized: "删除全部"), systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .confirmationDialog(
                String(localized: "删除全部对话？"),
                isPresented: $showDeleteAllConfirmation,
                titleVisibility: .visible
            ) {
                Button(String(localized: "删除全部"), role: .destructive) {
                    store.deleteAll()
                    engine.invalidateContext()
                }
            } message: {
                Text(String(localized: "此操作无法撤销。"))
            }
            .alert(String(localized: "重命名"), isPresented: renameBinding) {
                TextField(String(localized: "标题"), text: $renameText)
                Button(String(localized: "取消"), role: .cancel) { renamingID = nil }
                Button(String(localized: "保存")) {
                    if let renamingID { store.rename(renamingID, to: renameText) }
                    renamingID = nil
                }
            }
        }
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { renamingID != nil }, set: { if !$0 { renamingID = nil } })
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
                        Text(conversation.updatedAt, format: .relative(presentation: .named))
                        if !conversation.isEmpty {
                            Text("·")
                            Text(String(localized: "\(conversation.messages.count) 条消息"))
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
                Label(String(localized: "删除"), systemImage: "trash")
            }
            Button {
                renameText = conversation.customTitle ?? conversation.title
                renamingID = conversation.id
            } label: {
                Label(String(localized: "重命名"), systemImage: "pencil")
            }
            .tint(Palette.inkSecondary)
        }
    }

    private func select(_ id: UUID) {
        guard !engine.isGenerating else { return }
        store.select(id)
        // KV cache 里存的是上一个会话的历史，换会话必须让它失效。
        engine.invalidateContext()
        dismiss()
    }
}
