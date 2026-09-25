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
            // 新建浮在列表下方 —— 这是这一页最主要的动作，不该藏进右上角的菜单里。
            .safeAreaInset(edge: .bottom) { newNoteButton }
            .navigationTitle(L("Notes"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Palette.canvas, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(L("Close")) { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(role: .destructive) {
                        showDeleteAllConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(Palette.ink)
                    }
                    .accessibilityLabel(L("Delete all"))
                }
            }
            .confirmationDialog(
                L("Delete all notes?"),
                isPresented: $showDeleteAllConfirmation,
                titleVisibility: .visible
            ) {
                Button(L("Delete all"), role: .destructive) {
                    store.deleteAll()
                    engine.invalidateContext()
                }
            } message: {
                Text(L("This cannot be undone."))
            }
            .alert(L("Rename"), isPresented: renameBinding) {
                TextField(L("Title"), text: $renameText)
                Button(L("Cancel"), role: .cancel) { renamingID = nil }
                Button(L("Save")) {
                    if let renamingID { store.rename(renamingID, to: renameText) }
                    renamingID = nil
                }
            }
        }
    }

    private var newNoteButton: some View {
        Button {
            select(store.startNewConversation())
        } label: {
            Label(L("New note"), systemImage: "square.and.pencil")
                .font(.body.weight(.medium))
                .foregroundStyle(Palette.canvas)
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .background(Palette.ink, in: Capsule())
        }
        .padding(.bottom, 20)
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
                            Text(L("\(conversation.messages.count) messages"))
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
                Label(L("Delete"), systemImage: "trash")
            }
            Button {
                renameText = conversation.customTitle ?? conversation.title
                renamingID = conversation.id
            } label: {
                Label(L("Rename"), systemImage: "pencil")
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
