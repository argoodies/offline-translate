# QW

完全离线的 iOS / iPadOS AI 助手。Qwen3.5-0.8B 直接跑在设备上，对话不经过任何服务器。

模型随 app 一起安装，装完就能用。app 不发出任何网络请求 —— 开着飞行模式也能用。

## 它是怎么搭起来的

| 层 | 选型 | 为什么 |
| --- | --- | --- |
| 界面 | SwiftUI，iOS / iPadOS 16.4+ | 下限由 llama.cpp 的 xcframework 决定 |
| 推理 | llama.cpp（Metal 后端） | GGUF 生态成熟，0.8B 在 A 系芯片上够快 |
| 模型 | [Qwen3.5-0.8B](https://huggingface.co/Qwen/Qwen3.5-0.8B) GGUF，Q4_K_M（507 MB），随包安装 | 这个体积档里综合能力最好的一批，支持 201 种语言 |
| Markdown | [swift-markdown-ui](https://github.com/gonzalezreal/swift-markdown-ui) 2.4 | 系统的 `AttributedString(markdown:)` 不支持代码块和表格 |
| 朗读 | 系统 `AVSpeechSynthesizer` | 设备上已装的语音包同样离线；长按消息触发 |
| 配色 | 白底黑字，锁定浅色外观 | 见 `Palette.swift`，只有黑白灰，没有强调色 |
| 语言 | 全程英语 | 包里没有 `.lproj`，key 即显示文本 |
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
    Palette.swift         全 app 的黑白灰配色
    MarkdownStabilizer.swift  把流式中途的半截 Markdown 补成合法的
    SpeechReader.swift    朗读回复，按回复语言选系统语音
    AppSettings.swift     运行参数，全是常量
  Views/
    ChatView.swift             消息列表 + 输入栏，Markdown 渲染
    AirplaneGateView.swift     联网时挡在对话前的那一页
    ConversationListView.swift 会话切换、重命名、删除
```

## 本地构建

需要 macOS + Xcode 16 以上。

```bash
./scripts/build-llama-xcframework.sh   # 从源码编 llama.xcframework，首次约 10 分钟
./scripts/fetch-model.sh               # 拉 507 MB 权重到 Resources/Model/
brew install xcodegen
xcodegen generate
open QW.xcodeproj
```

然后选真机运行。**模拟器也能跑，但没有 Metal，推理会退回 CPU，慢十倍以上** —— 想知道真实速度请用真机。

## 几个实现上的选择

**多轮对话复用 KV cache。** 每轮只把新增的那段 prompt 喂进去（`LlamaBridge.extend`），而不是重新 decode 整段历史 —— 后者会让第十轮的首字延迟变成第一轮的十倍，而前面所有轮的状态本来就还躺在 cache 里。代价是要小心维护「cache 现在对应哪个会话、到哪一轮」：换会话、重新生成、中途停止都会让 cache 失效，这时才退回完整重建。

**上下文满了自动裁剪。** 装不下就丢掉最早的一轮问答重建，直到能放下，并在界面上说明「较早的对话已被裁剪」。悄悄丢历史比明说更糟 —— 用户会觉得模型突然失忆。

**不强制离线。** 早先的版本在联网时会挡住对话，逼用户去开飞行模式 —— 判定基于 `NWPathMonitor`，而 iOS 允许 Wi-Fi 独立于飞行模式开着并自动重连，于是「我明明开了飞行模式却进不去」成了常态。那道关卡已经拆掉：app 本来就不发任何网络请求，离线是事实而不需要靠拦人来证明。

**加载进度来自 llama.cpp 本身。** 半个 GB 的权重 mmap 进来要几秒，静止的画面看着像卡死。`llama_model_params.progress_callback` 会在加载过程中回调 0…1 的进度，接上就行，不用编个假动画。C 回调捕获不了 Swift 闭包，所以把接收方包成一个 class、用 `user_data` 带指针过去，并且 `withExtendedLifetime` 保证它活过整个加载 —— 传的是 unretained 指针。回调每加载一个 tensor 就来一次，几百上千次，所以跨过一个百分点才往外报一次。

模型没就绪就不构建对话界面 —— 不是拿遮罩盖住，是 `RootView` 根本不进那个分支。加载失败时整屏是错误页加一个重试按钮，只有加载成功（或重试成功）才进得去。原先只在输入栏上方挂一条错误文字，人除了杀掉 app 重开没有别的路 —— 而重开多半是同样的结果。

这里有个不能省的区分：**模型加载失败**和**单轮生成失败**必须是两个状态。早先它们共用 `.failed`，于是一旦按「没就绪不给进」来卡，生成时随便一个错误都会把人踢出对话界面，还告诉他模型加载失败。现在 `loadFailed` 接管整屏，`failed` 只在输入栏上方提一句 —— 模型还在，对话接着来。

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

上传需要仓库 secrets：`ASC_KEY_ID`、`ASC_ISSUER_ID`、`ASC_API_KEY_P8`。

归档前会先跑 `scripts/revoke-stale-certs.py`。`xcodebuild -allowProvisioningUpdates` 每归档一次就新建一张名为 "Created via API" 的开发证书，账号配额不大，攒满之后归档直接报 *Your account has reached the maximum number of certificates* —— 这个坑踩过两次。那些证书没有别的用处（下次要用会重新建），所以每次先清掉上一轮留下的。脚本只动 displayName 正好是 "Created via API" 的开发证书，开发者本人的和唯一那张分发证书都不碰。App Store Connect 侧复用已有的记录（app `6815647930`）；它的 bundle id 是当初用 Expo 建记录时自动生成的占位串，难看但已经在 Developer Portal 注册好，而且用户看不到它。

两个 workflow 都缓存 `llama.xcframework`（按 `LLAMA_REF`）和模型权重（按 `MODEL_KEY`），平时不会重编也不会重下。

## 许可

模型 Qwen3.5-0.8B 为 Apache-2.0。llama.cpp 为 MIT。
