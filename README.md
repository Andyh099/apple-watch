# 腕译 · Apple Watch 中英双向口译原型

**状态：iOS/watchOS 签名构建已通过，手机端与手表端均已安装并成功启动于实体设备（真机进程检查，用户亦确认手表可启动）。用户复测仍报 -1009；第二轮改为异步音频激活并补齐音频流配置，已安装。真机 HTTPS 200、无凭证 WebSocket 401 检查已通过，证明请求能到达中继；真实授权与翻译待测。录放音及云端翻译仍未验收，不能宣称已实现同传。**

## 1. 已确认的产品目标

- Siri 唤起或打开手表应用后，启动一次连续会话，不需要每句话按键。
- 听到中文直接播英文，听到英文直接播中文；根据输入切换方向。
- 只翻译，不说“好的”“现在开始翻译”，不回答原话里的问题，也不解释采用什么语气。
- 尽量保留原意、人称、数字、否定、礼貌程度和情绪；不承诺声音克隆。
- 手表显示原声/译文字幕并播音；不能把“整句说完才处理”冒充同传。
- iPhone 只做配置及未来订阅管理，不承担录音翻译。

首版工程暂名“腕译”，名称可改。多种表达、订阅、支付、手机结果同步尚未实现。优先验证最核心的双向连续语音。

## 2. 这份工程做了什么

| 部分 | 当前实现 | 未验证/未实现 |
| --- | --- | --- |
| watchOS | 连续 PCM 采集、流式播放、字幕、开始/结束、云处理同意、麦克风权限、网络错误停止 | 真机界面及录放音验收、扬声器音频路线、回声抑制、耗电和温升 |
| Siri | App Intent / App Shortcut 入口，打开前台应用；应用不返回口头开场白 | 真机快捷短语识别、权限交接、Siri 系统自身是否播报 |
| iPhone | WSS 地址及开发设备令牌配置、Keychain、WatchConnectivity 同步 | 实际手机/手表配对同步、账号、订阅和支付 |
| Node 后端 | 鉴权、双向 WebSocket 音频桥接、纯翻译提示词、输入限制、限时与并发上限 | 真实模型访问权限、延迟、语气、双语准确率与成本 |

**技术路线是实验性的。** 当前连接 GPT-Live 双工语音接口，使用纯翻译指令约束行为；指令不等于保证。专用翻译模型的固定目标语设置与“单个手表麦克风自动双向”之间仍需要方向路由设计，未假装接通这条方案。详见 [架构与边界](docs/architecture.md)。

**前台限制：** 当前退出前台即停止，返回不悄悄恢复录音。不能承诺息屏/放下手腕/后台时持续翻译。Siri 是启动入口，不是让第三方应用一直借用 Siri 的录音界面。

## 3. 先跑无需 API Key 的检查

环境：Node.js 22+、Swift 工具链。路径包含空格，命令保留引号。

```sh
cd "/Users/andy/Desktop/apple watch/server"
npm ci --ignore-scripts
npm run check
npm test

cd "/Users/andy/Desktop/apple watch"
bash scripts/test-core.sh
```

本机 2026-09-27 的结果：

- Node：**12 项测试通过**，包括真实 localhost WebSocket + 模拟上游，检查鉴权、并发、PCM 往返、字幕和结束时末尾音频顺序。
- Swift 核心：**19 条断言通过**，实际编译并执行，覆盖保留静音、音频拆包、字幕去重及地址/令牌校验。
- XCTest：**7 项测试通过**，使用完整 Xcode 的 Swift 工具链实际编译执行。
- Xcode 27.0：无签名设备/模拟器构建通过；随后使用用户批准的 Personal Team 完成两个 target 的签名构建，严格深度签名验证通过。手机端已安装到 iPhone 17 Pro Max；首次启动拦截后，用户已确认可以打开，真机进程检查通过。
- iPhone 17 / iOS 27.0 模拟器：App 已安装、启动，配置页面已截图检查，未配置服务或调用语音。
- Watch App Intent 元数据已生成，含中英文启动短语；Siri 真机交接仍未验证。
- 环境更正：此前只检查了默认 `xcode-select` 路径，误判没有完整 Xcode。进一步检查发现两套 Xcode；26.6 缺相应平台组件，27.0 可以构建。所有命令临时指定 `DEVELOPER_DIR`，未修改系统默认工具链。
- 实体 Apple Watch（Watch8,1 / watchOS 27.0.1）已连接且开发者模式已开启；独立重新签名构建及严格深度签名验证通过，描述文件包含该手表。首次安装、启动及进程检查通过。后续用户截图显示已同意云处理，但连接失败；2026-09-27 第二轮补丁使用异步音频激活、声明音频流能力，并通过手表无录音检查确认 HTTPS 200 / WebSocket 401（有意省略设备令牌）。配对配置内容及实际音频仍待验收。详情见 [原生验证记录](docs/verification.md)。
- **代理的构建和连接诊断未主动调用真实语音模型或录音；诊断只做健康请求及无凭证握手（服务器在连接模型前拒绝）。401 仅证明网络可达，不证明设备令牌有效、模型权限或翻译成功。**

## 4. 配置直连（不再经过 Mac 中转）

手表直连 OpenAI Live API，走手表自己的 Wi-Fi 或蜂窝网络。

1. 在 iPhone 上打开腕译，把 OpenAI API Key 粘贴进输入框，点"保存并同步到手表"。Key 只存于手机和手表的钥匙串，经系统加密通道同步，不会显示或记录。
2. 先在 OpenAI 后台给这个 Key 设置用量上限——Key 随设备丢失可能被刷额度。
3. 手表端收到 `session.started` 后才开始采集；单次会话 300 秒，超时自动结束。

`server/` 目录保留为旧中继实现（历史参考），当前默认不再使用。

## 5. 用完整 Xcode 运行

1. 准备支持相关 SDK 的完整 Xcode（本工程包含 watchOS 26 App Intents API 引用；部署目标为 iOS 18 / watchOS 11），以及配对的 iPhone 和 Apple Watch。本机已使用 Xcode 27.0 构建通过。
2. 打开 `WristInterpreter.xcodeproj`。这是 iPhone app + 单目标 watchOS app，不需要 CocoaPods、XcodeGen 或第三方 Swift 包。
3. 在两个 target 的 Signing & Capabilities 中设置自己的 Development Team；如需修改 Bundle ID，保持以下关系。本机已配置用户批准的 Personal Team：
   - iPhone 默认 `dev.wristinterpreter.prototype`
   - Watch 默认 `dev.wristinterpreter.prototype.watchkitapp`
   - 同时更新 `apps/Watch/Info.plist` 的 `WKCompanionAppBundleIdentifier` 为手机 Bundle ID，保持 Watch Bundle ID 与手机的前缀关系。
4. 选择 `WristInterpreter` scheme 在 iPhone 运行，再选择 `WristInterpreterWatch` scheme 在配对手表运行。本机签名构建及实体 iPhone / Watch 安装、启动已完成，用户已确认手表可启动。
5. 手机保存 WSS 地址和开发设备令牌。UI 的“已提交同步”不代表手表已经接收，需要手表端确认。
6. 首次在手表阅读云端处理说明并同意、授予麦克风权限。以非敏感内容测试双方语言，确认扬声器实际可听到译文。
7. 测试快捷短语“用腕译开始口译”，再验证冷启动、已打开、权限未授予等情况。不能宣称此流程可绕过系统授权。

`python3 scripts/generate-project.py` 可以重建工程，但会覆盖手动修改过的项目/共享 scheme 设置。完成签名配置后不要无意重新生成。

如命令行仍指向 Command Line Tools，可对单条命令指定工具链，不需要修改系统默认：

```sh
cd "/Users/andy/Desktop/apple watch"
DEVELOPER_DIR=/Applications/Xcode-27.0.0.app/Contents/Developer \
  xcodebuild -project WristInterpreter.xcodeproj -scheme WristInterpreter \
  -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath .build/XcodeDerivedData CODE_SIGNING_ALLOWED=NO build
```

## 6. 通过什么才算完成核心功能

按 [真机验收清单](docs/acceptance.md) 执行。特别是：

- 安静时不开场、不自行说话；中文英文自动互译；问句只翻译不回答。
- 连续长句未结束时已开始输出有意义的译文，且后续信息不丢失。
- 播音时仍能录音；不会把自己的扬声器译文反复译回去。
- 测量真实首音延迟、持续跟随延迟、丢字、错译及语气，而非用网络/单元测试结果推断。

如果这些不通过，应标记“同传目标未达成”，调整模型/路由/声学处理，而不是偷偷改成按句轮流录音。

## 隐私和生产边界

录音经你配置的服务器转发至 OpenAI，参与者应知情。本原型不主动持久化录音或字幕，字幕只保存在内存中；`store: false` **不代表服务商零留存**。自行部署的代理/监控也必须核查，避免记录 Authorization、音频或字幕。

生产发布前仍需完成独立账号与短期凭证、订阅权益验证、限额与费用统计、隐私及合规审查、App Store 所需资料/图标、本地化和真实设备验证。当前不是可上架版本，也没有付费功能。
