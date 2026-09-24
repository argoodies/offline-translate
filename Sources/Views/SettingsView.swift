import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var modelManager: ModelManager
    @EnvironmentObject private var engine: ChatEngine
    @Environment(\.dismiss) private var dismiss

    @State private var showDeleteConfirmation = false

    var body: some View {
        NavigationStack {
            Form {
                behaviourSection
                modelSection
                performanceSection
                aboutSection
            }
            .navigationTitle(String(localized: "设置"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(String(localized: "完成")) { dismiss() }
                }
            }
            .confirmationDialog(
                String(localized: "删除已下载的模型？"),
                isPresented: $showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button(String(localized: "删除"), role: .destructive) {
                    Task {
                        // 必须先卸载再删文件：llama 还 mmap 着它。
                        await engine.unloadModel()
                        modelManager.deleteInstalledModel()
                    }
                }
            } message: {
                Text(String(localized: "删除后需要重新下载才能继续对话。"))
            }
        }
    }

    private var behaviourSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "系统提示词"))
                    .font(.subheadline)
                TextEditor(text: $settings.systemPrompt)
                    .frame(minHeight: 90)
                    .font(.footnote)
                Button(String(localized: "恢复默认")) {
                    settings.resetSystemPrompt()
                }
                .font(.caption)
            }
            .padding(.vertical, 4)

            Toggle(String(localized: "显示思考过程"), isOn: $settings.showReasoning)
        } header: {
            Text(String(localized: "对话"))
        } footer: {
            Text(String(localized: "开启「显示思考过程」后，模型会先推理再作答 —— 更慢，但复杂问题上通常更准。关闭时它会跳过推理直接回答。改动在下一条消息生效。"))
        }
    }

    private var modelSection: some View {
        Section {
            if let variant = modelManager.installedVariant {
                LabeledContent(String(localized: "模型"), value: "Qwen3.5-0.8B")
                LabeledContent(String(localized: "精度"), value: variant.quantization)
                LabeledContent(String(localized: "占用空间"), value: variant.formattedSize)
            }
            if let description = engine.modelDescription {
                LabeledContent(String(localized: "架构"), value: description)
                    .font(.footnote)
            }
            Button(String(localized: "删除模型"), role: .destructive) {
                showDeleteConfirmation = true
            }
        } header: {
            Text(String(localized: "模型"))
        }
    }

    private var performanceSection: some View {
        Section {
            Picker(String(localized: "上下文长度"), selection: $settings.contextSize) {
                ForEach(AppSettings.contextSizeOptions, id: \.self) { size in
                    Text("\(size)").tag(size)
                }
            }

            Picker(String(localized: "单条回复上限"), selection: $settings.maxReplyTokens) {
                ForEach(AppSettings.replyLengthOptions, id: \.self) { size in
                    Text("\(size)").tag(size)
                }
            }

            Stepper(
                String(localized: "线程数：\(settings.threadCount)"),
                value: $settings.threadCount,
                in: 1...AppSettings.maxThreadCount
            )

            VStack(alignment: .leading) {
                Text(String(format: NSLocalizedString("随机度：%.2f", comment: ""), settings.temperature))
                    .font(.subheadline)
                Slider(value: $settings.temperature, in: 0.05...1.2, step: 0.05)
            }
        } header: {
            Text(String(localized: "性能"))
        } footer: {
            Text(String(localized: "上下文越长越能记住前面的对话，但会占用更多内存，在旧机型上可能导致 app 被系统结束。随机度越低回答越稳定、越高越发散。改动会重新加载模型。"))
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent(String(localized: "版本"), value: Self.appVersion)
            Link(destination: URL(string: "https://huggingface.co/Qwen/Qwen3.5-0.8B")!) {
                LabeledContent(String(localized: "模型主页"), value: "Qwen3.5-0.8B")
            }
            Link(destination: URL(string: "https://github.com/ggml-org/llama.cpp")!) {
                LabeledContent(String(localized: "推理引擎"), value: "llama.cpp")
            }
        } header: {
            Text(String(localized: "关于"))
        } footer: {
            Text(String(localized: "所有对话都在本机完成。这个 app 除了下载模型之外不会发送任何网络请求。"))
        }
    }

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
