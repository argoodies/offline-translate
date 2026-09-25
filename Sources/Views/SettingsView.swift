import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var engine: ChatEngine
    @EnvironmentObject private var language: LanguageSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                interfaceSection
                behaviourSection
                modelSection
                performanceSection
                aboutSection
            }
            .scrollContentBackground(.hidden)
            .background(Palette.canvas)
            .navigationTitle(L("Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Palette.canvas, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(L("Done")) { dismiss() }
                }
            }
        }
    }

    private var interfaceSection: some View {
        Section {
            Picker(L("Language"), selection: Binding(
                get: { language.current },
                set: { language.select($0) }
            )) {
                ForEach(AppLanguage.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
        } header: {
            Text(L("Interface"))
        }
    }

    private var behaviourSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("System prompt"))
                    .font(.subheadline)
                TextEditor(text: $settings.systemPrompt)
                    .frame(minHeight: 90)
                    .font(.footnote)
                Button(L("Reset to default")) {
                    settings.resetSystemPrompt()
                }
                .font(.caption)
            }
            .padding(.vertical, 4)

            Toggle(L("Show reasoning"), isOn: $settings.showReasoning)
        } header: {
            Text(L("Chats"))
        } footer: {
            Text(L("With reasoning shown, the model thinks before answering — slower, but usually better on hard questions. With it off, it answers directly. Takes effect on your next message.\n\nLong-press any message to have it read aloud — system voices, also fully offline."))
        }
    }

    private var modelSection: some View {
        Section {
            LabeledContent(L("Model"), value: BundledModel.displayName)
            LabeledContent(L("Precision"), value: BundledModel.quantization)
            if let size = BundledModel.formattedSize {
                LabeledContent(L("Size on disk"), value: size)
            }
            if let description = engine.modelDescription {
                LabeledContent(L("Architecture"), value: description)
                    .font(.footnote)
            }
        } header: {
            Text(L("Model"))
        } footer: {
            Text(L("The model ships with the app — nothing to download."))
        }
    }

    private var performanceSection: some View {
        Section {
            Picker(L("Context length"), selection: $settings.contextSize) {
                ForEach(AppSettings.contextSizeOptions, id: \.self) { size in
                    Text("\(size)").tag(size)
                }
            }

            Picker(L("Max reply length"), selection: $settings.maxReplyTokens) {
                ForEach(AppSettings.replyLengthOptions, id: \.self) { size in
                    Text("\(size)").tag(size)
                }
            }

            Stepper(
                L("Threads: \(settings.threadCount)"),
                value: $settings.threadCount,
                in: 1...AppSettings.maxThreadCount
            )

            VStack(alignment: .leading) {
                Text(String(format: L("Randomness: %.2f"), settings.temperature))
                    .font(.subheadline)
                Slider(value: $settings.temperature, in: 0.05...1.2, step: 0.05)
            }
        } header: {
            Text(L("Performance"))
        } footer: {
            Text(L("A longer context remembers more of the conversation but uses more memory, which can get the app killed on older devices. Lower randomness gives steadier answers, higher is more varied. Changes reload the model."))
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent(L("Version"), value: Self.appVersion)
            Link(destination: URL(string: "https://huggingface.co/Qwen/Qwen3.5-0.8B")!) {
                LabeledContent(L("Model page"), value: "Qwen3.5-0.8B")
            }
            Link(destination: URL(string: "https://github.com/ggml-org/llama.cpp")!) {
                LabeledContent(L("Inference engine"), value: "llama.cpp")
            }
        } header: {
            Text(L("About"))
        } footer: {
            Text(L("All chat happens on-device. This app makes no network requests at all."))
        }
    }

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
