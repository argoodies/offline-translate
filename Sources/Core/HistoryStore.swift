import Foundation
import Combine

struct TranslationRecord: Identifiable, Codable, Hashable {
    var id = UUID()
    var date = Date()
    var sourceCode: String?
    var targetCode: String
    var input: String
    var output: String
    var isPinned = false

    var sourceLanguage: TranslationLanguage? {
        sourceCode.flatMap(TranslationLanguage.language(forCode:))
    }

    var targetLanguage: TranslationLanguage? {
        TranslationLanguage.language(forCode: targetCode)
    }
}

/// 历史记录。存本地 JSON —— 数据量小（几百条短文本），没必要为此引入 SwiftData 和它的迁移负担。
@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var records: [TranslationRecord] = []

    /// 未收藏的记录只保留最近这些条，避免文件无限增长。
    private static let unpinnedLimit = 200

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            return base.appendingPathComponent("history.json")
        }()
        load()
    }

    func add(input: String, output: String, source: TranslationLanguage?, target: TranslationLanguage) {
        let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty, !trimmedOutput.isEmpty else { return }

        // 反复微调同一段文字很常见，同源同目标的重复原文只保留最新一条。
        records.removeAll { $0.input == trimmedInput && $0.targetCode == target.code && !$0.isPinned }
        records.insert(
            TranslationRecord(
                sourceCode: source?.code,
                targetCode: target.code,
                input: trimmedInput,
                output: trimmedOutput
            ),
            at: 0
        )
        prune()
        save()
    }

    func togglePin(_ record: TranslationRecord) {
        guard let index = records.firstIndex(where: { $0.id == record.id }) else { return }
        records[index].isPinned.toggle()
        save()
    }

    func delete(_ record: TranslationRecord) {
        records.removeAll { $0.id == record.id }
        save()
    }

    func delete(atOffsets offsets: IndexSet, in visible: [TranslationRecord]) {
        let ids = offsets.map { visible[$0].id }
        records.removeAll { ids.contains($0.id) }
        save()
    }

    func clearAll() {
        records.removeAll { !$0.isPinned }
        save()
    }

    private func prune() {
        var unpinnedSeen = 0
        records = records.filter { record in
            guard !record.isPinned else { return true }
            unpinnedSeen += 1
            return unpinnedSeen <= Self.unpinnedLimit
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        records = (try? JSONDecoder().decode([TranslationRecord].self, from: data)) ?? []
    }

    private func save() {
        let snapshot = records
        let url = fileURL
        // 写盘放到后台：用户按下收藏时不该等待 I/O。
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: url, options: .atomic)
        }
    }
}
