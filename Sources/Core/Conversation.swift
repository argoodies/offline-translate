import Foundation

struct ChatMessage: Identifiable, Codable, Hashable {
    enum Role: String, Codable {
        case user
        case assistant
    }

    var id = UUID()
    var role: Role
    var text: String
    /// 模型的思考过程。只有在设置里开启「显示思考过程」时才会被保留下来。
    var reasoning: String?
    var date = Date()
    /// 回复是因为撞到长度上限而停的，不是模型自己说完了。
    var isTruncated = false
}

struct Conversation: Identifiable, Codable, Hashable {
    var id = UUID()
    var messages: [ChatMessage] = []
    var createdAt = Date()
    var updatedAt = Date()
    /// 用户手动改过的标题。没改过就按第一条消息现算，这样重命名不会被后续消息覆盖。
    var customTitle: String?

    var title: String {
        if let customTitle, !customTitle.isEmpty { return customTitle }
        guard let first = messages.first(where: { $0.role == .user })?.text else {
            return L("New chat")
        }
        let line = first
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        return line.count > 24 ? String(line.prefix(24)) + "…" : line
    }

    var isEmpty: Bool { messages.isEmpty }
}

/// 所有会话的存储。JSON 文件即可 —— 纯文本对话即使攒上几千条也就几 MB，
/// 为此引入 SwiftData 只会换来一堆 schema 迁移的麻烦。
@MainActor
final class ChatStore: ObservableObject {
    @Published private(set) var conversations: [Conversation] = []
    @Published var currentID: UUID?

    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            return base.appendingPathComponent("conversations.json")
        }()
        load()
        if conversations.isEmpty {
            startNewConversation()
        } else {
            currentID = conversations.first?.id
        }
    }

    var current: Conversation? {
        guard let currentID else { return nil }
        return conversations.first { $0.id == currentID }
    }

    var currentMessages: [ChatMessage] {
        current?.messages ?? []
    }

    // MARK: - 会话

    @discardableResult
    func startNewConversation() -> UUID {
        // 已经有一个空白会话就复用它，免得列表里攒出一堆「新对话」。
        if let existing = conversations.first(where: { $0.isEmpty }) {
            currentID = existing.id
            return existing.id
        }
        let conversation = Conversation()
        conversations.insert(conversation, at: 0)
        currentID = conversation.id
        scheduleSave()
        return conversation.id
    }

    func select(_ id: UUID) {
        currentID = id
    }

    func delete(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        if currentID == id {
            currentID = conversations.first?.id
            if currentID == nil { startNewConversation() }
        }
        scheduleSave()
    }

    func deleteAll() {
        conversations.removeAll()
        currentID = nil
        startNewConversation()
        scheduleSave()
    }

    func rename(_ id: UUID, to title: String) {
        guard let index = index(of: id) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        conversations[index].customTitle = trimmed.isEmpty ? nil : trimmed
        scheduleSave()
    }

    // MARK: - 消息

    func append(_ message: ChatMessage, to id: UUID) {
        guard let index = index(of: id) else { return }
        conversations[index].messages.append(message)
        conversations[index].updatedAt = Date()
        moveToTop(index)
        scheduleSave()
    }

    /// 重新生成最后一条回复：把它连同之前那条 user 消息一起取出来。
    func popLastExchange(in id: UUID) -> String? {
        guard let index = index(of: id) else { return nil }
        var messages = conversations[index].messages
        guard let lastAssistant = messages.lastIndex(where: { $0.role == .assistant }) else { return nil }
        messages.removeSubrange(lastAssistant...)
        guard let lastUser = messages.lastIndex(where: { $0.role == .user }) else { return nil }
        let prompt = messages[lastUser].text
        messages.removeSubrange(lastUser...)
        conversations[index].messages = messages
        scheduleSave()
        return prompt
    }

    // MARK: - 持久化

    private func index(of id: UUID) -> Int? {
        conversations.firstIndex { $0.id == id }
    }

    private func moveToTop(_ index: Int) {
        guard index > 0 else { return }
        let conversation = conversations.remove(at: index)
        conversations.insert(conversation, at: 0)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        conversations = (try? JSONDecoder().decode([Conversation].self, from: data)) ?? []
    }

    /// 流式生成时每个 token 都会改动会话，逐次写盘会把磁盘打满。合并成一次延迟写。
    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = conversations
        let url = fileURL
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await Self.write(snapshot, to: url)
        }
    }

    private static func write(_ conversations: [Conversation], to url: URL) async {
        await Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(conversations) else { return }
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: url, options: .atomic)
        }.value
    }
}
