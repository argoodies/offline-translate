import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var modelManager: ModelManager
    @EnvironmentObject private var engine: TranslationEngine

    @State private var showDeleteConfirmation = false

    var body: some View {
        NavigationStack {
            Form {
                translationSection
                modelSection
                performanceSection
                aboutSection
            }
            .navigationTitle(String(localized: "设置"))
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
                Text(String(localized: "删除后需要重新下载才能继续翻译。"))
            }
        }
    }

    private var translationSection: some View {
        Section {
            Picker(String(localized: "语气"), selection: $settings.tone) {
                ForEach(TranslationTone.allCases) { tone in
                    Text(tone.label).tag(tone)
                }
            }

            Toggle(String(localized: "输入后自动翻译"), isOn: $settings.autoTranslate)
            Toggle(String(localized: "保存历史记录"), isOn: $settings.saveHistory)
        } header: {
            Text(String(localized: "翻译"))
        } footer: {
            Text(String(localized: "历史记录只保存在本设备，不会同步，也不参与 iCloud 备份。"))
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

            Stepper(
                String(localized: "线程数：\(settings.threadCount)"),
                value: $settings.threadCount,
                in: 1...AppSettings.maxThreadCount
            )

            Toggle(String(localized: "结果可复现"), isOn: $settings.deterministicOutput)

            if !settings.deterministicOutput {
                VStack(alignment: .leading) {
                    Text(String(format: NSLocalizedString("随机度：%.2f", comment: ""), settings.temperature))
                        .font(.subheadline)
                    Slider(value: $settings.temperature, in: 0.05...1.0, step: 0.05)
                }
            }

            Toggle(String(localized: "跳过模型思考过程"), isOn: $settings.suppressThinking)
        } header: {
            Text(String(localized: "性能"))
        } footer: {
            Text(String(localized: "上下文越长越能翻整段文字，但会占用更多内存。关闭「跳过思考过程」会让模型先推理再作答，更慢，个别难句可能更准。改动会重新加载模型。"))
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
            Text(String(localized: "所有翻译都在本机完成。这个 app 除了下载模型之外不会发送任何网络请求。"))
        }
    }

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
