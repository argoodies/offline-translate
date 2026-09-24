import SwiftUI
import UIKit

struct HistoryView: View {
    @EnvironmentObject private var history: HistoryStore

    @State private var searchText = ""
    @State private var showClearConfirmation = false

    private var visibleRecords: [TranslationRecord] {
        let sorted = history.records.sorted { lhs, rhs in
            // 收藏永远置顶，其余按时间倒序。
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            return lhs.date > rhs.date
        }
        guard !searchText.isEmpty else { return sorted }
        return sorted.filter {
            $0.input.localizedCaseInsensitiveContains(searchText)
                || $0.output.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if history.records.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle(String(localized: "历史"))
            .toolbar {
                if !history.records.isEmpty {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(String(localized: "清空"), role: .destructive) {
                            showClearConfirmation = true
                        }
                    }
                }
            }
            .confirmationDialog(
                String(localized: "清空历史记录？"),
                isPresented: $showClearConfirmation,
                titleVisibility: .visible
            ) {
                Button(String(localized: "清空（保留收藏）"), role: .destructive) {
                    history.clearAll()
                }
            }
        }
    }

    private var list: some View {
        List {
            ForEach(visibleRecords) { record in
                recordRow(record)
                    .swipeActions(edge: .leading) {
                        Button {
                            history.togglePin(record)
                        } label: {
                            Label(
                                record.isPinned ? String(localized: "取消收藏") : String(localized: "收藏"),
                                systemImage: record.isPinned ? "star.slash" : "star"
                            )
                        }
                        .tint(.yellow)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            history.delete(record)
                        } label: {
                            Label(String(localized: "删除"), systemImage: "trash")
                        }
                    }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $searchText, prompt: String(localized: "搜索译文"))
    }

    private func recordRow(_ record: TranslationRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if record.isPinned {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                }
                Text(languagePairLabel(record))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(record.date, format: .relative(presentation: .named))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Text(record.input)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Text(record.output)
                .font(.body)
                .lineLimit(4)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                UIPasteboard.general.string = record.output
            } label: {
                Label(String(localized: "复制译文"), systemImage: "doc.on.doc")
            }
            Button {
                history.togglePin(record)
            } label: {
                Label(
                    record.isPinned ? String(localized: "取消收藏") : String(localized: "收藏"),
                    systemImage: record.isPinned ? "star.slash" : "star"
                )
            }
            Button(role: .destructive) {
                history.delete(record)
            } label: {
                Label(String(localized: "删除"), systemImage: "trash")
            }
        }
    }

    private func languagePairLabel(_ record: TranslationRecord) -> String {
        let source = record.sourceLanguage?.displayName ?? String(localized: "自动")
        let target = record.targetLanguage?.displayName ?? record.targetCode
        return "\(source) → \(target)"
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tertiary)
            Text(String(localized: "还没有翻译记录"))
                .font(.headline)
            Text(String(localized: "翻译过的内容会保存在这里，全部存在本地。"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
    }
}
