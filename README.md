# Aero

完全离线的 iOS AI 助手。Qwen3.5-0.8B 直接跑在设备上，对话不经过任何服务器。

模型随 app 一起安装，装完就能用。app 不发出任何网络请求 —— 开着飞行模式也能用，名字就是这么来的。

## 它是怎么搭起来的

| 层 | 选型 | 为什么 |
| --- | --- | --- |
| 界面 | SwiftUI，iOS 16.4+ | 下限由 llama.cpp 的 xcframework 决定 |
| 推理 | llama.cpp（Metal 后端） | GGUF 生态成熟，0.8B 在 A 系芯片上够快 |
| 模型 | [Qwen3.5-0.8B](https://huggingface.co/Qwen/Qwen3.5-0.8B) GGUF，Q4_K_M（507 MB），随包安装 | 这个体积档里综合能力最好的一批，支持 201 种语言 |
| Markdown | [swift-markdown-ui](https://github.com/gonzalezreal/swift-markdown-ui) 2.4 | 系统的 `AttributedString(markdown:)` 不支持代码块和表格 |
| 朗读 | 系统 `AVSpeechSynthesizer` | 设备上已装的语音包同样离线；长按消息触发 |
| 工程文件 | XcodeGen（`project.yml`） | `.xcodeproj` 不进仓库，避免 pbxproj 的合并地狱 |

```
Sources/
  Core/
    LlamaBridge.swift     actor，封装 llama.cpp 的 C API；reset / extend / step 的流式解码
    ChatPrompt.swift      ChatML 增量拼接 + 流式输出清洗
    ChatEngine.swift      编排：加载模型、复用或重建 KV cache、跑生成
    Conversation.swift    消息与会话模型，本地 JSON 存储
    BundledModel.swift    定位 bundle 里的权重文件
    NetworkGate.swift     NWPathMonitor，判断当前是否离线
    SpeechReader.swift    朗读回复，按回复语言选系统语音
    AppSettings.swift     用户设置
  Views/
    ChatView.swift             消息列表 + 输入栏，Markdown 渲染
    AirplaneGateView.swift     联网时挡在对话前的那一页
    ConversationListView.swift 会话切换、重命名、删除
    SettingsView.swift         系统提示词、性能参数
```

## 本地构建

需要 macOS + Xcode 16 以上。

```bash
./scripts/build-llama-xcframework.sh   # 从源码编 llama.xcframework，首次约 10 分钟
./scripts/fetch-model.sh               # 拉 507 MB 权重到 Resources/Model/
brew install xcodegen
xcodegen generate
open Aero.xcodeproj
```

然后选真机运行。**模拟器也能跑，但没有 Metal，推理会退回 CPU，慢十倍以上** —— 想知道真实速度请用真机。

## 几个实现上的选择

**多轮对话复用 KV cache。** 每轮只把新增的那段 prompt 喂进去（`LlamaBridge.extend`），而不是重新 decode 整段历史 —— 后者会让第十轮的首字延迟变成第一轮的十倍，而前面所有轮的状态本来就还躺在 cache 里。代价是要小心维护「cache 现在对应哪个会话、到哪一轮」：换会话、重新生成、中途停止都会让 cache 失效，这时才退回完整重建。

**上下文满了自动裁剪。** 装不下就丢掉最早的一轮问答重建，直到能放下，并在界面上说明「较早的对话已被裁剪」。悄悄丢历史比明说更糟 —— 用户会觉得模型突然失忆。

**联网时不让进对话。** Aero 的主张是不被打扰，所以入口直接把这件事变成一个动作：去打开飞行模式，检测到断网自动放行。

需要说清楚的是，iOS **没有公开 API 能查「飞行模式是否开启」**，能查的只有网络可达性（`NWPathMonitor`）。开了飞行模式必然无网，但反过来不成立 —— 关掉 Wi-Fi 和蜂窝也算。对这个 app 来说效果等价，文案按飞行模式写。这一页还留了个「仍要继续」的出口：状态判断依赖系统回调，真出现误判时不该把人锁死在启动页。

**App 图标是自己画的飞机，不是 SF Symbol。** Apple 的 SF Symbols 许可禁止把 symbol（以及「实质上或容易混淆地相似」的字形）用作 app icon，并保留要求整改的权利。飞机剪影本身是通用符号，所以 `scripts/make_appicon.py` 用多边形画了一个：先在 4 倍画布上填充，再靠「高斯模糊 + 阈值」把尖角统一磨圆 —— 比在每个顶点手工插贝塞尔控制点省事得多。

**流式时不渲染 Markdown。** 生成中途的 Markdown 是半截的 —— 没闭合的代码块、写了一半的表格 —— 每 50 毫秒重新解析一次会让界面疯狂闪烁。所以生成时走纯文本，收尾后再交给 MarkdownUI。图片 provider 换成了只读 asset 的版本，堵死它默认的远程图片加载：这个 app 不该有任何出网路径。

**模型打包进 app。** 装完就能用 —— 没有等待、没有下载失败、没有「装了 app 却用不了」的中间状态，也不需要任何网络权限。代价是安装包 500 MB 出头，蜂窝网络下 App Store 会多问用户一次。

权重本身不进 git（GitHub 单文件上限 100 MB，LFS 的免费配额也撑不住），由 `scripts/fetch-model.sh` 在构建前拉取，CI 里按文件名缓存。

**默认抑制模型的思考过程。** Qwen3.5 是 hybrid thinking 模型，prompt 里给 assistant 开头塞一个空的 `<think></think>` 块就会跳过推理直接作答。日常问答不需要思考链，省下的全是首字延迟。设置里可以打开，打开后思考内容会折叠显示在回复上方。

**手写 ChatML** 而不是 `llama_chat_apply_template` —— 后者不是 Jinja 解析器，只认内置的一批模板名，新模型经常落不到正确分支。Qwen 全系列都是 ChatML，手写反而更可靠。

**流式输出要自己拼 UTF-8。** token 切片会把一个汉字劈成两半，直接转 String 就是乱码。`LlamaBridge` 内部按字节缓冲，只在能构成完整字符时才吐出去。

## 升级 llama.cpp

`scripts/build-llama-xcframework.sh` 里的 `LLAMA_REF` 固定在某个 tag（当前 `b11158`）。上游的 C API 变动频繁，浮动到 master 会让构建随机挂掉。升级时：

1. 改 `LLAMA_REF`，同步改两个 workflow 里的 `env.LLAMA_REF`（缓存键要一致）；
2. `FORCE_REBUILD=1 ./scripts/build-llama-xcframework.sh`；
3. 对着 `include/llama.h` 的 diff 检查 `LlamaBridge.swift` —— 结构体字段被改名是常事（比如 `use_mmap` 已经被 `load_mode` 枚举取代）。

## CI

- `.github/workflows/ci.yml` —— push / PR 时编译验证（模拟器，不签名）。
- `.github/workflows/ios-testflight.yml` —— 手动触发，归档并上传 TestFlight。

上传需要仓库 secrets：`ASC_KEY_ID`、`ASC_ISSUER_ID`、`ASC_API_KEY_P8`。App Store Connect 侧复用已有的记录（app `6815647930`）；它的 bundle id 是当初用 Expo 建记录时自动生成的占位串，难看但已经在 Developer Portal 注册好，而且用户看不到它。

两个 workflow 都缓存 `llama.xcframework`（按 `LLAMA_REF`）和模型权重（按 `MODEL_KEY`），平时不会重编也不会重下。

## 许可

模型 Qwen3.5-0.8B 为 Apache-2.0。llama.cpp 为 MIT。
