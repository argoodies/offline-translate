# QW

完全离线的 iOS / iPadOS AI 记事本。Qwen3.5-0.8B 直接跑在设备上，对话不经过任何服务器。

模型随 app 一起安装，装完就能用。app 不发出任何网络请求 —— 开着飞行模式也能用。

## 它是怎么搭起来的

| 层 | 选型 | 为什么 |
| --- | --- | --- |
| 界面 | SwiftUI，iOS / iPadOS 18.6+ | 硬约束是 16.4（xcframework 的编译目标），定得更高是主动选的 |
| 推理 | llama.cpp（Metal 后端） | GGUF 生态成熟，0.8B 在 A 系芯片上够快 |
| 模型 | [Qwen3.5-0.8B](https://huggingface.co/Qwen/Qwen3.5-0.8B) GGUF，Q4_K_M（507 MB），随包安装 | 这个体积档里综合能力最好的一批，支持 201 种语言 |
| Markdown | [swift-markdown-ui](https://github.com/gonzalezreal/swift-markdown-ui) 2.4 | 系统的 `AttributedString(markdown:)` 不支持代码块和表格 |
| 朗读 | 系统 `AVSpeechSynthesizer` | 设备上已装的语音包同样离线；长按消息触发 |
| 配色 | 黑白灰，跟随系统深浅色 | 见 `Palette.swift`，没有强调色 |
| 文案 | 正文页几乎没有词 | 只有 QW 和一句 `Start writing`；启动页和失败页有英文，详见下文 |
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
    Palette.swift         全 app 的黑白灰配色，跟随深浅色
    Haptics.swift         触觉反馈
    StreamPacer.swift     把模型的突发输出摊平成匀速显示
    MarkdownStabilizer.swift  把流式中途的半截 Markdown 补成合法的
    SpeechReader.swift    朗读回复，按回复语言选系统语音
    AppSettings.swift     运行参数，全是常量
  Views/
    NoteView.swift             一整页文档：正文流、行内输入、Markdown 渲染
    ConversationListView.swift 会话切换与删除
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

**上下文满了自动裁剪。** 装不下就丢掉最早的一轮问答重建，直到能放下，并在顶栏用一条细线显示余量。悄悄丢历史比明说更糟 —— 用户会觉得模型突然失忆。

**不强制离线。** 早先的版本在联网时会挡住对话，逼用户去开飞行模式 —— 判定基于 `NWPathMonitor`，而 iOS 允许 Wi-Fi 独立于飞行模式开着并自动重连，于是「我明明开了飞行模式却进不去」成了常态。那道关卡已经拆掉：app 本来就不发任何网络请求，离线是事实而不需要靠拦人来证明。

**配色跟随系统深浅色。** 整套黑白灰在深色下原样翻过来，用户气泡始终是界面上唯一的大块反色。取色用 `UIColor` 的动态构造而不是两个静态 `Color` —— 系统切换外观时它自己重算，不用在每个视图里读 `colorScheme` 再手动挑一个。灰阶全部用中性灰而不是系统那套 `systemGray`，后者带蓝调，铺在纯白上能看出偏色。app 内的 Logo 是张黑色图，按 template 渲染再染成前景色，否则深色下会糊在黑底上。

**正文界面上几乎没有词。** 写字那一页上只有两处字样：顶栏的 QW（产品名，也是空笔记的标题），和整页还空着时输入位置上的 `Start writing`。其余文案都换成了图形：截断提示是一个省略号，上下文余量是一条会填满的细线，长按菜单是三个裸图标，时间是 `09/25/2026` 这样的纯数字。

有三处留了英文，都是「不说清楚就只能干等或乱猜」的地方：启动页照实说现在在读权重还是在准备 GPU（这两步的体感完全不同，统称一句 Loading 会让最难熬的那几秒像卡死）；加载失败把 llama.cpp 报的原话写出来，因为「文件坏了」和「内存不够」该做的事不一样；列表页的新建按钮带着 New text 标签。

起因是这些文案全是英文，于是这个 app 就成了一个英文 app —— 对一个「跑在你自己设备上、背后没有任何服务」的东西来说，这个属性很奇怪。译成多语言是另一条路，但那要塞进一整套 `.lproj`，还要挑默认语言，跟这个 app 的性格不合。

有两个功能是删掉而不是翻译的：**删除全部**要确认框，**重命名**要输入框，而这两种弹窗都必须写「取消 / 确定」。删除改成逐条左滑，标题跟备忘录一样取正文第一行 —— 两边都没留下多大的洞。

`accessibilityLabel` 保留英文。它们不画在屏幕上，只给 VoiceOver 读；界面现在全是图标，去掉这些等于让需要它的人完全没法用。

**界面是一页文档，不是一串气泡。** 自己写的和模型回的都在同一条流里，从左上往下排，没有气泡也没有左右分边，只靠字重区分（自己写的略重）。输入框就嵌在文档末尾：点屏幕任意处光标落到那儿。**收起键盘就是落笔** —— 没有发送按钮，blur 本身就是提交动作，写完收笔，那段原地定格，回答接着在下一行写出来。收笔只有两个入口：光标下方那半屏留白，和右上角的勾。中间试过「点正文任意处都收笔」，结果写着写着蹭一下屏幕就发出去了 —— 收笔即提交，是个收不回来的动作，入口越少越好。剩下那两处都在正在写的内容后面，往那儿点本来就带着「写完了」的意思，位置本身就是意图。点已经写好的段落之间只落笔，不收笔。

切换记事和新建都是先清空 draft 再 blur，所以那两处不会误提交。

进到一页笔记就自动落笔，空的和写满的一样。打开一页笔记本来就是为了写东西，还要再点一下屏幕纯属多余。中间有一版只在空白笔记上这么做，理由是「翻回旧笔记多半是为了看」—— 但那是替人猜意图，而收键盘的代价远小于每次都多点一下，不想写往下一滑就收了。生成中例外：那时候输入框不在视图里，位置让给正在写出来的回答。焦点要等一拍再提：这一下多半跟列表页的收起动画一起发生，而转场当中提焦点系统会直接忽略，键盘根本不会上来。

正文下面留半屏空白。一页纸本来就不会在最后一行戛然而止，而这块空白同时是收笔的主入口 —— 没在写就落笔，正在写就收笔。它还顺带让短笔记也能滑动：不然内容不够长时 `scrollDismissesKeyboard` 根本触发不了，下滑收键盘那条路等于不存在。

开始写的时候会把下方那半屏留白滑出来，让落笔的位置尽量靠上 —— 否则光标贴着键盘，能看见的正文只剩一两行。

新建记事那颗按钮浮在列表页下方，而不是藏在右上角的菜单里：那是这一页最主要的动作。

**输出速率要自己摊平。** llama.cpp 的出字节奏很不均匀：prompt 吃完之后会一下子涌出一批，碰上长 token 又顿一下。原先按时间片把这段时间攒的字一次性糊上去，屏幕上就是一块一块地跳。`StreamPacer` 在中间放一个待显示队列，以 30fps 的固定节奏往外放：积压多就每次多放几个字（按一个约 12 帧的追赶窗口摊开），积压少就一个一个来，节奏始终是稳的。生成结束时把追赶窗口收到 4 帧加速放完 —— 人已经等完了，不该再等着看完。

这同时解决了三件事：显示丝滑、节奏不抖、触觉有稳定的节拍可跟。按下停止时队列里没放出去的直接丢掉 —— 用户按的是停止，不是「放完再停」。

**触觉反馈。** 发送时一次 light 敲击；生成时每放出一段文字敲一下，用 soft —— 它比 light 钝得多，密集触发时不会变成一串刺耳的敲击。节奏由 `StreamPacer` 给（约 30 次/秒），再限一道 45ms 下限压到每秒二十次上下：密到能连成一串「正在打字」的手感，又不至于糊成一阵分不出颗粒的嗡嗡声。发生器提前 `prepare()`，否则第一次触发有几十毫秒延迟，正好错过它要标记的那个瞬间。只有 iPhone 有 Taptic Engine，iPad 上这些调用什么也不会发生，但不会出错。

**App 图标是画出来的。** `scripts/make_appicon.py` 用 PIL 渲染白底黑字的 QW，同一套遮罩出两张图：图标贴在渐变白底上（不留 alpha，否则 App Store 会拒），app 内那张是透明底。

字号不是拍脑袋定的 —— 二分搜索求出让字形外框正好占到目标宽度比例的字号，换文案或换字体都不用重调一个魔数。居中分两个方向：横向按真实墨迹，纵向按**大写字母主体**。不用 `anchor` 是因为字体自带的行高会把重心带偏；纵向要单独量，则是因为 Q 的尾巴垂在基线以下，把它算进居中会把字母主体整体顶上去 —— 拿一个没有下伸部、主体等高的串（`OW`）去量就对了。

**工具栏两个图标要对齐。** `line.3.horizontal` 和 `checkmark.circle` 的字形高度和光学重心并不一致，直接摆上去一高一低；统一字号再塞进等大的方框才横平竖直。右上角那个位置上「保存」和「停止」轮流出现，所以两者都取带圆圈的那版（`checkmark.circle` / `stop.circle`）—— 一个光秃秃的勾配一个带圈的方块，每次切换视觉直径都跳一下。

**加载进度来自 llama.cpp 本身。** 半个 GB 的权重 mmap 进来要几秒，静止的画面看着像卡死。`llama_model_params.progress_callback` 会在加载过程中回调 0…1 的进度，接上就行，不用编个假动画。C 回调捕获不了 Swift 闭包，所以把接收方包成一个 class、用 `user_data` 带指针过去，并且 `withExtendedLifetime` 保证它活过整个加载 —— 传的是 unretained 指针。回调每加载一个 tensor 就来一次，几百上千次，所以跨过一个百分点才往外报一次。

模型没就绪就不构建对话界面 —— 不是拿遮罩盖住，是 `RootView` 根本不进那个分支。加载失败时整屏写出 llama.cpp 报的原话加一个 Try again，只有加载成功（或重试成功）才进得去。原先只在输入栏上方挂一条错误文字，人除了杀掉 app 重开没有别的路 —— 而重开多半是同样的结果。

这里有个不能省的区分：**模型加载失败**和**单轮生成失败**必须是两个状态。早先它们共用 `.failed`，于是一旦按「没就绪不给进」来卡，生成时随便一个错误都会把人踢出对话界面，还告诉他模型加载失败。现在 `loadFailed` 接管整屏，`failed` 不打断任何东西 —— 模型还在，对话接着来。

**建上下文要不到内存就退一档。** 权重读完之后，`llama_init_from_model` 还要在那 507 MB 之上再要 KV cache 和计算图缓冲，而这一步会失败 —— 同一组参数昨天跑得好好的，今天开机就报 `contextCreationFailed`。差别不在代码，在设备当时的状态：手机烫的时候，Metal 内核编译和 GPU 缓冲申请正是系统最先拒绝的东西。

所以不认死一组数：要不到就把 `n_ctx` 和 `n_ubatch` 一起减半再要，最多退三档。一个只能记住 1024 token 的 app，总好过一个打不开的 app。模型这时已经在内存里了，重试只是再建一次上下文，不用重读那半个 G。生效的是真正拿到的那一组 —— 分块喂 prompt 和裁剪历史都读实际值，不读当初想要的值。

**模型打包进 app。** 装完就能用 —— 没有等待、没有下载失败、没有「装了 app 却用不了」的中间状态，也不需要任何网络权限。代价是安装包 500 MB 出头，蜂窝网络下 App Store 会多问用户一次。

权重本身不进 git（GitHub 单文件上限 100 MB，LFS 的免费配额也撑不住），由 `scripts/fetch-model.sh` 在构建前拉取，CI 里按文件名缓存。

**默认抑制模型的思考过程。** Qwen3.5 是 hybrid thinking 模型，prompt 里给 assistant 开头塞一个空的 `<think></think>` 块就会跳过推理直接作答。日常问答不需要思考链，省下的全是首字延迟。这个 app 没有设置界面，所以它是定死的。

**手写 ChatML** 而不是 `llama_chat_apply_template` —— 后者不是 Jinja 解析器，只认内置的一批模板名，新模型经常落不到正确分支。Qwen 全系列都是 ChatML，手写反而更可靠。

**流式输出要自己拼 UTF-8。** token 切片会把一个汉字劈成两半，直接转 String 就是乱码。`LlamaBridge` 内部按字节缓冲，只在能构成完整字符时才吐出去。

## 升级 llama.cpp

`scripts/build-llama-xcframework.sh` 里的 `LLAMA_REF` 固定在某个 tag（当前 `b11158`）。上游的 C API 变动频繁，浮动到 master 会让构建随机挂掉。升级时：

1. 改 `LLAMA_REF`，同步改两个 workflow 里的 `env.LLAMA_REF`（缓存键要一致）；
2. `FORCE_REBUILD=1 ./scripts/build-llama-xcframework.sh`；
3. 对着 `include/llama.h` 的 diff 检查 `LlamaBridge.swift` —— 结构体字段被改名是常事（比如 `use_mmap` 已经被 `load_mode` 枚举取代）。

## CI

一条流水线走完：`.github/workflows/release.yml`。push 和 PR 只做模拟器编译；手动触发时两个开关各管一条出口 —— `release` 归档并上传 TestFlight，`distribute` 导一个 ad-hoc 包发到 Fly 上的下载页。两者共用同一个 archive，签名方式是导出时才定的。

之所以合成一个文件：分成两个 workflow 时，两条各自 checkout、各自恢复缓存、各自拉一遍 507 MB 模型，一次发布白花一倍时间。

之所以发布仍要手动点：中间有一版改成了推到 main 就出包，结果当天上传二十多次，撞上 App Store Connect 的每日上传配额（`409 Upload limit reached`），连着三条流水线挂在上传那一步。发布次数该由「这版值得发」决定，而不是由「刚好推了一次」决定。

上传需要仓库 secrets：`ASC_KEY_ID`、`ASC_ISSUER_ID`、`ASC_API_KEY_P8`；下载页另需 `FLY_API_TOKEN` 和 `FLY_APP_NAME`。

主机名之所以也是 Secret：那一页不能设密码 —— iOS 取 `itms-services` 清单时不带凭据，加了认证就装不上 —— 所以不可猜的主机名是它仅有的一层遮挡，写进这个公开仓库等于没遮。最初它确实硬编码在 `fly.toml` 里，是后来才挪走的。就算漏了也不是灾难：ad-hoc 描述文件只认账号里登记过的设备，别人下到的包装不上；遮的是「谁都能下走这半个 G」，不是「谁都能装」。

ad-hoc 那条排在 TestFlight 上传前面。一个步骤挂了后面的就不跑，而上传恰好是最容易挂的一步（每日配额 409）—— 排在后面的话，一次配额用尽会把本来好好的下载页也一起赔进去。

归档前会先跑 `scripts/revoke-stale-certs.py`。`xcodebuild -allowProvisioningUpdates` 每归档一次就新建一张名为 "Created via API" 的开发证书，账号配额不大，攒满之后归档直接报 *Your account has reached the maximum number of certificates* —— 这个坑踩过两次。那些证书没有别的用处（下次要用会重新建），所以每次先清掉上一轮留下的。脚本只动 displayName 正好是 "Created via API" 的开发证书，开发者本人的和唯一那张分发证书都不碰。App Store Connect 侧复用已有的记录（app `6815647930`）；它的 bundle id 是当初用 Expo 建记录时自动生成的占位串，难看但已经在 Developer Portal 注册好，而且用户看不到它。

`llama.xcframework`（按 `LLAMA_REF`）和模型权重（按 `MODEL_KEY`）都有缓存，平时不会重编也不会重下。

## 许可

模型 Qwen3.5-0.8B 为 Apache-2.0。llama.cpp 为 MIT。
