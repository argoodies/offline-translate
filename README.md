# 没网翻译 / Offline Translate

完全离线的 iOS 翻译 app。Qwen3.5-0.8B 直接跑在设备上，文字不经过任何服务器。

除了首次下载模型权重那一次，app 不发出任何网络请求。

## 它是怎么搭起来的

| 层 | 选型 | 为什么 |
| --- | --- | --- |
| 界面 | SwiftUI，iOS 16.4+ | 下限由 llama.cpp 的 xcframework 决定 |
| 推理 | llama.cpp（Metal 后端） | GGUF 生态成熟，0.8B 在 A 系芯片上够快 |
| 模型 | [Qwen3.5-0.8B](https://huggingface.co/Qwen/Qwen3.5-0.8B) GGUF，默认 Q4_K_M（507 MB） | 支持 201 种语言，是这个体积档里翻译质量最好的一批 |
| 语种识别 | 系统 `NaturalLanguage` | 离线、免费、不占模型上下文 |
| 朗读 | 系统 `AVSpeechSynthesizer` | 用设备上已装的离线语音包 |
| 工程文件 | XcodeGen（`project.yml`） | `.xcodeproj` 不进仓库，避免 pbxproj 的合并地狱 |

```
Sources/
  Core/
    LlamaBridge.swift        actor，封装 llama.cpp 的 C API；prepare + step 的流式解码
    TranslationPrompt.swift  ChatML prompt 构造 + 流式输出清洗
    TranslationEngine.swift  编排层：加载模型、跑生成、统计速度
    ModelManager.swift       background URLSession 下载、校验、安装
    ModelCatalog.swift       可选的量化档位
    TranslationLanguage.swift  语言表 + 离线语种识别
    HistoryStore.swift       本地 JSON 历史记录
    AppSettings.swift        用户设置
    SpeechReader.swift       朗读
  Views/                     翻译 / 历史 / 设置 / 模型安装
```

## 本地构建

需要 macOS + Xcode 16 以上。

```bash
./scripts/build-llama-xcframework.sh   # 从源码编 llama.xcframework，首次约 10 分钟
brew install xcodegen
xcodegen generate
open PocketLingo.xcodeproj
```

然后选真机运行。**模拟器也能跑，但没有 Metal，推理会退回 CPU，慢十倍以上** —— 测试翻译质量请用真机。

## 几个实现上的选择

**模型不打包进 app。** 半 GB 的二进制会把安装包顶到 App Store 的蜂窝下载限制以上，而且用户想换量化档位就得整包更新。代价是首次启动需要联网下一次 —— 装完之后就是真正的全程离线。下载走 background URLSession，切到后台继续，支持暂停续传。

**默认走贪心解码**（设置里可关）。同一句话每次都给同样的译文；翻译任务里输出跳动只会让人觉得 app 不稳定。

**抑制模型的思考过程。** Qwen3.5 是 hybrid thinking 模型，prompt 里给 assistant 开头塞一个空的 `<think></think>` 块就会跳过推理直接作答。翻译不需要思考链，省下的全是首字延迟。设置里可以关掉。

**手写 ChatML 而不是调 `llama_chat_apply_template`。** 后者不是 Jinja 解析器，只认内置的一批模板名，新模型经常落不到正确分支。Qwen 全系列都是 ChatML，手写反而更可靠。

**流式输出要自己拼 UTF-8。** token 切片会把一个汉字劈成两半，直接 `String(cString:)` 会得到乱码。`LlamaBridge` 内部按字节缓冲，只在能构成完整字符时才吐出去。

## 升级 llama.cpp

`scripts/build-llama-xcframework.sh` 里的 `LLAMA_REF` 固定在某个 tag（当前 `b11158`）。上游的 C API 变动频繁，浮动到 master 会让构建随机挂掉。升级时：

1. 改 `LLAMA_REF`，同步改两个 workflow 里的 `env.LLAMA_REF`（缓存键要一致）；
2. `FORCE_REBUILD=1 ./scripts/build-llama-xcframework.sh`；
3. 对着 `include/llama.h` 的 diff 检查 `LlamaBridge.swift` —— 结构体字段被改名是常事（比如 `use_mmap` 已经被 `load_mode` 枚举取代）。

## CI

- `.github/workflows/ci.yml` —— push / PR 时编译验证（模拟器，不签名）。
- `.github/workflows/ios-testflight.yml` —— 手动触发，归档并上传 TestFlight。

上传需要仓库 secrets：`ASC_KEY_ID`、`ASC_ISSUER_ID`、`ASC_API_KEY_P8`。

App Store Connect 侧复用已有的**没网翻译**记录（app `6815647930`，SKU `translator.offline.io.github.argoodies`）。它的 bundle id `dev.expo.client.cdk6asipshwbwfmintawzxd2uwcbu5iejxt3t4gqkoq4o` 是当初用 Expo 建记录时自动生成的占位串 —— 难看，但已经在 Developer Portal 注册好（identifier `WCU9XWSGJG`），而且用户看不到它。要换成正常的 id 只能去网页端改，API 不支持改 `bundleId`。

两个 workflow 都把 `llama.xcframework` 按 `LLAMA_REF` 缓存，只有升级版本时才会重编。

## 许可

模型 Qwen3.5-0.8B 为 Apache-2.0。llama.cpp 为 MIT。
