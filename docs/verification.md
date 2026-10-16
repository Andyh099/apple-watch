# 原生构建、模拟器与真机安装验证记录

日期：2026-09-27。范围包括本地编译、核心测试、模拟器配置页启动、实体 iPhone / Apple Watch 安装、启动及首次连接错误修复。代理未主动发起真实语音测试；用户已尝试连接，但翻译成功仍未验证。

## 环境发现与更正

默认 `xcode-select -p` 指向 `/Library/Developer/CommandLineTools`，但不代表没有安装 Xcode。本次额外检查 `/Applications`：

- Xcode 26.6（17F113）：能枚举 SDK，但项目 destination 报告 iOS/watchOS 26.5 平台未安装，不能用于此次构建。
- Xcode 27.0（27A266a）：iOS/watchOS 通用设备与模拟器 destination 可用于构建。
- iOS 27.0 模拟器运行时可用，iPhone 17 模拟器已用于安装、启动验证。
- 后续检查已发现 watchOS 27.0 模拟器运行时，但未运行 Watch App。
- 实体 iPhone 17 Pro Max / iOS 27.0 已连接且开发者模式已开启；后续 Apple Watch（Watch8,1 / watchOS 27.0.1）已完成开发配对，设备检查确认已连接且开发者模式已开启。
- 初次环境检查时 `server/.env` 不存在；后续配置和临时通道见下文，不代表当前仍未配置。

仅给命令设置 `DEVELOPER_DIR`，没有修改系统的 `xcode-select` 配置，没有下载模拟器或签署开发者协议。

## 通过的检查

| 检查 | 结果与范围 |
| --- | --- |
| iOS Debug 设备构建 | `BUILD SUCCEEDED`；包含 watchOS companion；关闭代码签名 |
| watchOS Debug 设备构建 | 随 iPhone scheme 依赖构建通过，产物平台 `WatchOS` |
| iOS/watchOS 模拟器构建 | `BUILD SUCCEEDED`；两个应用产物均存在 |
| iOS 模拟器安装、启动 | iPhone 17 / iOS 27.0 成功启动配置页，进程存在，截图检查 |
| Watch App Intent 元数据 | `StartInterpretingIntent`、前台启动及中英文快捷短语均被提取 |
| 核心 XCTest | 7 项，0 失败（含新增连接诊断测试） |
| 独立 Swift smoke | 19 条断言通过 |
| Node 协议/中继测试 | 12 项，0 失败；包括 localhost 模拟上游集成测试 |

手机 target 的 App Intents metadata extraction 提示没有 AppIntents.framework 依赖，这是配置端没有 intent 的现状；Watch target 已生成实际 intent 元数据。未将该提示伪装成 Siri 功能已验证。

## 本轮小范围修复

- 将 Watch 的已弃用录音授权 API 更新为 `AVAudioApplication.requestRecordPermission`。
- 明确音频播放异步闭包的捕获方式，消除编译器捕获告警；不改变音频流程。
- 修复手机首次空配置也显示“配置已保存”的状态错误，恢复为“尚未配置翻译服务”。该问题是在实际模拟器截图中发现的。

## 重现命令

在仓库根目录运行：

```sh
export DEVELOPER_DIR=/Applications/Xcode-27.0.0.app/Contents/Developer

xcodebuild -project WristInterpreter.xcodeproj -scheme WristInterpreter \
  -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath .build/XcodeDerivedData CODE_SIGNING_ALLOWED=NO build

xcodebuild -project WristInterpreter.xcodeproj -scheme WristInterpreter \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/XcodeDerivedData CODE_SIGNING_ALLOWED=NO build

swift test --scratch-path "$(mktemp -d /private/tmp/wrist-interpreter-tests.XXXXXX)"
bash scripts/test-core.sh
npm --prefix server run check
npm --prefix server test
```

XCTest 最初在桌面工作区内构建时，生成的测试 bundle 带有 Finder/file-provider 扩展属性，导致临时签名失败。改用专用 `/private/tmp` 构建目录后，签名和全部 5 项测试通过。没有清除用户文件扩展属性或关闭系统安全机制。

本地记录（`.build` 被版本库忽略）：

- `.build/verification/ios-build.log`
- `.build/verification/simulator-build.log`
- `.build/verification/swift-tests.log`
- `.build/verification/iphone-settings.png`

## 实体设备首次安装（后续检查）

用户批准后，为两个 target 的 Debug/Release 配置同一个 Personal Team，保留自动签名和原 Bundle ID。Xcode 创建开发证书和描述文件；签名构建使用专用 `/private/tmp` DerivedData，未重新生成工程。

- 签名构建 `BUILD SUCCEEDED`；iPhone app 及内嵌 Watch app 的严格深度签名校验通过。
- 描述文件未过期，包含连接的 iPhone；不代表包含实体 Watch。
- `devicectl device install app` 成功。
- 首次启动失败：CoreDeviceError 10002 / FBSOpenApplicationErrorDomain 3。系统列出的可能原因是签名、权限或用户尚未显式信任描述文件。当时请用户检查开发者信任。后续用户确认已可打开；未单独审计用户执行了哪些信任操作。
- 后续用户确认已可启动；`devicectl device info processes --search WristInterpreter` 确认实体 iPhone 上 App 进程存在（PID 681）。启动检查通过，但未进行真机界面截图验收、配置同步或功能测试。
- 未由代理绕过安全检查或修改设备信任，未录音、配置云端凭证或调用模型。
- 后续手机进程检查记录于 `.build/verification/device-process-check.json`。当时尚未检测到实体手表；下节记录完成 Watch 开发配对后的结果。
- 本地日志：`.build/verification/device-signed-build.log`、`device-install.json`、`device-launch.json`；构建路径在 `device-derived-data-path.txt`。

## 实体 Apple Watch 安装、启动（后续检查）

- 用户完成手表开发配对后，`devicectl` 和 Watch scheme destination 均识别到实体 Apple Watch；设备型号 `Watch8,1`，watchOS 27.0.1（24R365），开发者模式已开启。
- 安装前按 Bundle ID 查询，未发现已安装的手表应用。
- 首次复用手机 DerivedData 的增量构建虽报告成功，但更新后的 `embedded.mobileprovision` 未触发重新签名，严格签名验证失败；该产物未安装。保留日志 `watch-incremental-build.log`。
- 改用全新的专用 `/private/tmp` DerivedData 完整构建，`BUILD SUCCEEDED`；`codesign --verify --deep --strict` 通过。描述文件包含该实体手表且未过期（到期时间 2026-10-04 22:59:13 UTC），Bundle ID 和手机 companion ID 保持不变；未手动强制重签或关闭安全检查。
- `devicectl device install app` 和 `device process launch` 均成功；随后进程检查确认 `WristInterpreterWatch` 正在运行（PID 436）。未重新安装手机应用。
- 未点击“同意并开始”、未授予麦克风权限、未开启录音或调用云端翻译。启动代码在申请麦克风或联网前先检查云处理同意及配置；当时 `server/.env` 仍不存在。
- 安装、启动及进程检查后，用户进一步确认“手表上可以启动”。未取得实体手表界面截图，也未验收配置同步、录放音或 Siri 交接。
- 证据位于 `.build/verification/`：`watch-details.json`、`watch-destinations.log`、`watch-app-before-install.json`、`watch-signed-build.log`、`watch-codesign-verify.log`、`watch-signing-check.json`、`watch-install.json`、`watch-launch.json`、`watch-process-check.json`；新构建路径记录于 `watch-derived-data-path.txt`。

## 后端配置准备（用户确认手表可启动后）

- 根据 `.env.example` 创建本地 `server/.env`，文件权限为仅当前用户可读写（0600），生成随机开发设备令牌；未在输出或聊天中显示令牌。
- 初次创建时 `OPENAI_API_KEY` 留空；用户后续确认已保存。只输出非敏感检查结果：密钥非空、基本格式符合预期、配置能被后端解析、文件仍为纯文本且权限为 0600；未输出或记录密钥及设备令牌。基本格式检查不代表密钥有效或有模型访问权限。
- 已使用 `npm start` 启动本地中继；监听仅为 `127.0.0.1:8787`，单会话及 300 秒会话时限保持不变。未部署为常驻系统服务。
- 本机 `/health` 返回 HTTP 200，`providerConnectionVerified: false`；不带设备令牌的 WebSocket 握手被拒绝（HTTP 401）。证据：`.build/verification/relay-local-health.json`。
- 当时尚未部署公网端点；下节记录用户批准后的临时通道。仍未连接模型、开启录音或发送音频，真实密钥有效性、模型权限及手机到手表的配置同步仍待验证。

## 临时加密测试通道（用户批准后）

- 用户在获知临时公网地址、设备令牌保护及音频会经过通道服务商后，同意建立测试通道。
- 从 Cloudflare 官方 GitHub 发布页下载 Apple Silicon 版 `cloudflared` 2026.9.3，安装在项目 `.build/tools/`；下载包 SHA-256 与官方发布资产元数据一致。未全局安装、创建账号、申请域名或设置自启。
- 通道只转发至本机中继 `127.0.0.1:8787`，指标端口也绑定回环；未关闭 TLS 校验，未修改防火墙或把本地明文端口绑定公网接口。
- 经公网 HTTPS 请求 `/health` 返回 200 且 `providerConnectionVerified: false`；无令牌和错误令牌的 WebSocket 握手均返回 401；`/.env` 路径返回 404。
- 以上未发送正确令牌发起语音会话，未请求模型、录音或产生此次测试的模型用量；还未验证认证后的 WebSocket 音频流。
- 手机配置材料仅写入本机 `.build/腕译-手机连接配置.txt`（0600，目录被忽略），包含临时 WSS 地址和开发设备令牌，不含 OpenAI API Key。未将令牌打印到日志或聊天。
- 本地证据：`.build/verification/cloudflared-install.json`、`cloudflared-tunnel.log`、`tunnel-health.json`。后端和通道均为当前开发进程；测试需 Mac 保持联网运行，停止后不保证继续可用。

## 首次连接错误与手表补丁（2026-09-27）

- 用户照片显示“会话已停止 / 翻译连接中断或配置无效”及“撤回云端处理同意”。只能确认用户端出现失败和已同意状态，不能据此确认服务地址、设备令牌已正确同步或录音已经开始。
- 本机和公网 `/health` 均为 200；修复前通道只有健康检查及拒绝测试请求，没有成功的 101 升级记录。具体失败原因仍需补丁实测确认。
- 原逻辑先打开 `URLSessionWebSocketTask`，收到后端 `ready` 才激活音频。Apple TN3135 与 WWDC2019 Session 716 说明 watchOS 低层音频网络需要先激活音频会话；这构成启动顺序缺陷，但不能在未复测时称其为本次报错的唯一根因。
- 现改为同意与麦克风授权 → 激活 `.playAndRecord` / `.voiceChat` 音频会话 → 建立 WebSocket → 收到 `ready` → 创建引擎并开始采集。预备阶段不安装输入 tap、不采集或上传语音；开始采集检查会话 ID，避免过时连接启动录音。取消、退后台等真实竞态仍须真机验收。
- 增加 HTTP 授权/地址/服务错误与 URLSession 网络错误的分类提示，仅显示受控文案、状态/错误码，不输出原始错误、地址或凭证。
- 7 项 XCTest、19 条 Swift smoke 断言通过；源码顺序检查通过（非运行时测试）。Watch Debug 真机目标 `BUILD SUCCEEDED`；严格深度签名检查通过，描述文件包含目标 Watch 且未过期，签名团队和 Bundle ID 未变。
- `devicectl device install app` 确认补丁安装成功。随后携带 Debug 专用 `--diagnostics-no-autostart` 参数尝试启动，命令报告 CoreDeviceError 4000（刚连接即断开）。未盲目重启；只读进程复查确认新安装目录中的 `WristInterpreterWatch` 正在运行（PID 460）。该进程检查不能单独确认启动参数已接收或界面正常。
- 启动检查后本机/公网健康仍为 200，通道仍没有 101 升级记录；代理未点击开始或主动连接上游模型。实际语音、音频路线和模型权限仍待用户短时、非敏感内容复测。
- 证据：`.build/verification/watch-network-fix-tests.log`、`watch-network-fix-static-checks.json`、`watch-network-fix-build.log`、`watch-network-fix-codesign.log`、`watch-network-fix-signing.json`、`watch-network-fix-install.json`、`watch-network-fix-launch.json`、`watch-network-fix-processes.json`、`watch-network-fix-health-before-launch.json`、`watch-network-fix-health-after-launch.json`。失败启动结果保留，未覆盖为成功。

## -1009 复测与异步音频激活修复（2026-09-27）

- 用户第二张照片明确显示网络错误 -1009；上一轮“先 setActive(true)，后联网”补丁不足以解决真实设备问题。不能把该错误直接归因为用户断网或密钥错误。
- 重新读取 Apple `AVAudioSession.activate(options:completionHandler:)` 文档，明确它用于异步激活，并说明其他 category/policy 也应通过该方法授权。WWDC2019 Session 716 同时要求为音频流应用声明 Audio Background Mode。先前对文档的“其他类别使用 setActive”解释不正确，已更正实现。
- `DuplexAudio.prepareForConnection` 改为等待异步 `activate` 回调；保持 `.playAndRecord` / `.voiceChat`，没有切换到只播音的 playback，也没有冒用 VoIP/CallKit。拒绝重叠激活，过时回调清理路线且不能开始采集。
- Watch Info.plist 增加 `UIBackgroundModes = [audio]`，请求标为 `.avStreaming`。应用已有 `scenePhase.background → reset()` 保持不变；声明音频流能力不代表产品现在支持息屏或后台同传。
- 添加仅 Debug 的 `--diagnostics-network-check`：先用手表已有配置请求同源 HTTPS `/health`，再激活音频，向 `/interpret` 发起**不带 Authorization** 的 WebSocket 握手。不创建音频引擎、不装输入 tap、不上传 PCM，也不调用真实模型。正常用户点击开始仍走原有同意与麦克风授权流程。
- 首次指定真机 destination 构建因 Xcode 连接等待超时未完成；改用 generic watchOS destination 后签名 Debug 构建成功。严格深度签名校验通过，描述文件包含手表且未过期。补丁安装成功（安装目录 `7E8E0DF5-D31F-430D-8251-30F0C26028B1`）。
- **真机诊断已运行：** `https_status=200` → `audio_activation=success capture=off` → `websocket_status=401 error=-1011`。这里 -1011 是无授权握手被服务器返回 401 后的结果，不是先前的 -1009；省略令牌是本次无模型调用检查的设计。
- 通道响应计数同期 200 从 6 到 7、401 从 2 到 3。结合手表控制台，只能确认 HTTPS 与 WebSocket 握手请求到达该中继；尚未证明带令牌握手升级成功或模型 ready。
- `devicectl --console` 输出了上述诊断后，持续附着进程直到设定的 50 秒整体超时，退出码 2。没有把这个命令退出码改称成功；诊断结果按实际输出与服务计数记录。不要为了移除该工具超时而自动开始真实录音。
- Release watchOS 无签名构建也通过，确认 Debug 诊断代码隔离后生产配置可编译；该 Release 产物未安装。诊断后只读进程检查确认已安装的 Debug 补丁仍运行（PID 472）。
- 7 项 XCTest、19 条 Swift smoke、12 项 Node 测试全部通过。Node 鉴权拒绝测试使用会在被调用时失败的上游替身，确认无令牌请求在上游连接之前被拒绝；测试成功不证明真实模型权限。
- 本轮同时更正一处沟通错误：聊天曾把未成功读取的 Apple 论坛帖子当作支持证据；此说法已撤回。修复依据是实际读取的 API 文档、WWDC 讲解以及此次真机诊断，不使用该论坛帖子作依据。
- 本地证据：`.build/verification/watch-activation-api-evidence.json`、`watch-async-fix-build.log`（destination 超时）、`watch-async-fix-generic-build.log`、`watch-async-fix-codesign.log`、`watch-async-fix-signing.json`、`watch-async-fix-install.json`、`watch-async-fix-diagnostic-console.log`、`watch-async-fix-diagnostic-result.json`、`watch-async-fix-static-checks.json`、`watch-async-fix-tests.log`、`watch-async-fix-node-tests.log`。

## 仍然不能宣称完成的部分

- 实体 iPhone 界面与配置功能验收；手机/手表配对配置同步、手表 UI/录音/扬声器路线。
- Siri 冷启动与权限交接、息屏/离开前台的实际行为。
- 真实模型权限、双向翻译、无开场白的稳定性、语气保留、同传延迟。
- 外放回声、打断/重叠发言、末字完整性、功耗和网络变化。

下一步由用户保持 Mac 后端/通道运行，在手表手动点“开始翻译”短时复测；若仍失败，记录完整错误码再定位。需确保参与者知情，只用非敏感内容。配置是否正确同步、真实模型权限与录放音不能由安装结果推断。项目 Key 不应发到聊天或填入移动端。验收按 `acceptance.md` 执行。


## 麦克风短暂出现后无响应：中断处理修复与诊断（2026-09-27）

- 用户报告连接已正常，但麦克风短暂出现后消失，说话没有反应。没有该次会话的控制台/界面错误证据，不能把麦克风图标出现等同于采集成功，也不能断言此次根因已经定位。
- 只读检查：中继 `/health` 200；当时本机中继没有已建立的 TCP 会话。通道有新增 429，说明至少一次请求受到并发限制，不证明这就是用户那次故障。未修改并发上限，也未主动发起带设备令牌的模型连接。
- 明确的源码缺陷：原观察者收到任何 `AVAudioSession.interruptionNotification` 都停止会话，没有区分 `.began` 和 `.ended`。现只对 `.began` 停止；缺失/未知类型和 `.ended` 不误停，也不自动重开麦克风。通知在已指定的 main queue 上同步处理，移除额外 Task 延迟。Apple interruptionNotification 文档确认 began/ended 的不同语义；这是代码缺陷修复，非该次真机根因证明。
- 在已有音频串行队列增加捕获检查：引擎停止或五秒没有非空 PCM 回调时清晰报错并终止，不再无限显示正在收音。静音仍产生 PCM，不按音量判断失效；停止采集、旧 generation 和取消状态不再巡检/重启。tap 使用弱引用，避免引擎与拥有者的循环引用。
- 界面区分等待服务、启动麦克风、收到 PCM、已发送音频和收到译音；只有真的收到麦克风帧后显示“麦克风开启”。这些状态不能单独证明识别/翻译正确。保持原有离开前台停止行为，没有新增后台录音能力，也没有替换服务模型或协议。
- Debug 新增受控阶段名称和帧数日志，不记录录音、字幕、令牌或地址；安全启动参数增加明确的“尚未录音”提示。未知音频启动错误只显示数值错误码，不透传原始错误内容。
- 验证：Debug watchOS 构建无 warning 成功，严格签名通过；Release 无签名构建成功，二进制无诊断日志/启动参数字符串。原有 7 XCTest、19 smoke 断言、12 Node 测试通过。另提取生产中断回调和巡检方法，在 macOS 使用通知元数据/引擎 stub 验证 13+5 条断言；这不是 watchOS 真实音频中断或录音测试。
- 真机安装成功。携带 `--diagnostics-no-autostart` 的远程启动命令整体 30 秒超时，未盲目重启；之后只读进程查询成功，新安装目录 `B78D8D4D-7126-4BE8-99E1-D89A384BBC50` 中进程 PID 480 在运行。这证明新版进程存在，不单独确认界面与参数的实际效果。代理未点击录音，真实中英双向录音/译音仍需用户主动测试。
- 本轮修改仅 `apps/Watch/DuplexAudio.swift`、`apps/Watch/InterpreterSession.swift`、`apps/Watch/WristInterpreterApp.swift` 和本验证记录；签名配置、手机应用、服务端未改动。
- 证据：`.build/verification/watch-mic-fix-*`，摘要 `watch-mic-fix-result.json`；修改前备份 `watch-mic-fix-before/`。后续请记录用户保持前台点“开始翻译”后，麦克风消失时屏幕的完整状态和橙色错误提示。


## 视频确认录音引擎启动后停止：启动配置恢复补丁（2026-09-27）

- 已检查用户提供的 `IMG_6881.mov`（约 18.92 秒）及前后段抽帧：界面从服务已就绪、启动麦克风进入“正在等待麦克风音频”，约一至两秒后显示“会话已停止 / 录音引擎已停止，请保持腕译在前台并重新开始”。重复操作出现同样现象。应用界面一直存在，并未退回表盘；视频显示的是录音会话停止，不是应用闪退，也未显示收到 PCM。
- 该文案来自巡检中 `engine.isRunning == false` 分支，说明引擎在 `start()` 返回后停止。此前“保持前台”的提示并不符合视频观察，现已去掉该误导性建议。按 Wrist 名称查询设备崩溃日志返回零文件；这不排除所有崩溃情况。设备统一日志收集因需要 root 失败，没有取得具体音频事件日志。
- Apple 的 AVAudioEngineConfigurationChange 文档及本机 SDK 说明，音频硬件采样率/声道配置变化可使引擎停止，必要时需要按新格式重新连接。但本次视频没有证明配置变化通知实际发生；这是待真机验证的恢复路径，不是已确认根因。启动时的非必要震动也已移除，同样不能断言震动就是触发原因。
- `DuplexAudio.swift` 监听当前引擎的配置变化通知，仅派发到现有音频串行队列处理。在尚未收到非空 PCM、没有待播音频、引擎已停止时，延迟 250ms 读取新硬件格式并重建连接和输入 tap；每个会话最多两次，重复通知合并。仍要求 voice processing，不重新激活音频会话、不重连模型。已开始采集/播放后的配置变化明确报错，不丢弃或重放内容来假装修复。
- tap 和延迟恢复检查会话及采集 generation，停止、取消或旧回调不能重开录音。保留前台限制、中断停止、同意流程和后台协议。错误区分 `AUDIO-ENGINE`、`AUDIO-ROUTE`、`AUDIO-NO-PCM`；Debug 仅记录受控事件，不记录音频、字幕、密钥、令牌或地址。
- 验证通过：watchOS Debug 构建、严格深度签名检查、Release 无签名构建；Release 产物检查不含诊断日志及安全启动参数。7 项 XCTest、19 条 Swift smoke 断言、12 项 Node 测试通过；另以生产恢复方法配合 stub 引擎验证 16 条控制流断言，包含去重、次数上限、取消、采集/播放状态及失败路径。这些不能代替真实 watchOS 录音验证。
- 最新 Debug 已安装到目标 Apple Watch。`devicectl` 启动明确返回 success，并确认参数 `--diagnostics-no-autostart` 和 PID 494；此次不再仅依赖超时后的进程检查。启动成功不代表录音或翻译成功，代理未点击开始翻译，未主动发起模型语音会话。
- 本轮生产代码仅修改 `apps/Watch/DuplexAudio.swift` 与 `apps/Watch/InterpreterSession.swift`；未修改签名、手机配置、服务端或翻译协议。证据为 `.build/verification/watch-engine-fix-*`、`watch-crash-video/`、`watch-crash-list.*`、`watch-engine-device-log-collect.log` 与 `watch-engine-configuration-apple.json`；修改前备份保留在 `watch-engine-fix-before/`。
- 待用户主动复测：点一次“开始翻译”，观察能否持续显示“麦克风开启 · 直接说话”，再用非敏感短句测试译文和外放。若再次停止，记录完整橙色错误标记；目前不能宣称故障已修复或同传已经可用。


## “地铁站”误识别：连续音频转换修复（2026-09-27）

- 用户反馈“地铁站怎么走”被识别为“第一次……”。目前没有这次会话的输入音频、原声字幕/译文截图或硬件采样率，不能判断用户指的是原声字幕还是译音，也不能宣称误识别的唯一根因已经找到。没有新增录音保存、上传测试语音或代用户开启麦克风。
- 检查现有原声字幕为上游 delta 原样追加；服务输入保持 24kHz 单声道 PCM16，未发现固定中文/英文锁定或客户端文本替换。重新获取官方 Live 音频、提示词及字幕文档，只用于核对；未更换模型、协议或提示词，未把测试句写入模型指令。
- 从旧生产 tap 提取转换逻辑，在 macOS 使用真实 AVAudioConverter 和合成音频复现数据丢失：16kHz 的 10 秒输入以 2048/480/1024/4096/512/1536/127 个采样的变长块送入，输出仅 226,548 个 24kHz 采样，相比 240,000 约短 560.5ms。调试计数显示 8,952 个输入采样所在的 tap 未被 converter 请求就被丢弃。此结果证明旧转换实现存在缺陷，不证明该次 Watch 使用了 16kHz 或该块序列。
- 原实现每个 tap 只调用一次 convert，并忽略输入回调请求的采样数：转换器可能只输出内部缓存而不请求新 tap；一次返回过长输入也不符合请求长度。新增串行使用的 `StreamingPCMConverter`，按请求长度和偏移供给输入，持续取出输出直到 `inputRanDry`，检查输入已消耗；不通过删除静音、复制片段或改变采样率标签掩盖错误。Watch tap 使用该实现，保留现有 100ms 分帧、generation 校验、语音处理、启动恢复、同意和前台限制。
- 同一 10 秒合成测试修复后得到 239,976 个采样，剩余 24 个采样（1ms）为未结束流的转换器延迟；24/44.1/48kHz 的时长、音量和频率检查也通过。新增 5 项正式 XCTest，覆盖四种输入采样率、固定/极小/变长 tap、单声道、交错和非交错立体声、空输入、静音及格式变化。分块输出与完整块转换输出逐字节对比相同，避免只看音频长度忽略漏音/重复。
- 12 项 XCTest（原有 7 + 新增 5）、19 条 Swift smoke 断言、12 项 Node 测试通过。watchOS Debug/Release 构建成功、无编译告警，Debug 严格深度签名通过。测试构建最初因 Desktop 资源扩展属性签名失败，已改用 `/private/tmp` 构建，不把环境失败记作测试通过。
- Debug 只增加输入采样率/声道数日志，不记录语音、字幕或凭证。Release 首次检查发现格式诊断字符串残留，已用编译条件完整包围调用并重建，最终 Release 不含音频/会话/网络诊断和安全启动参数字符串。Xcode 仅增加新文件引用，所有原有 build configurations 与签名设置逐字相同，未运行项目生成脚本。
- 本轮文件：`Sources/InterpreterCore/StreamingPCMConverter.swift`、`Tests/InterpreterCoreTests/StreamingPCMConverterTests.swift`、`apps/Watch/DuplexAudio.swift`、Xcode 项目的文件引用及本记录。证据为 `.build/verification/recognition-*`，旧代码和项目备份在 `recognition-before/`。真实 Watch 识别准确率仍需用户主动复测；不要把合成音频测试称为语言识别准确率测试。
- 最终 Debug 真机安装成功。安全参数 `--diagnostics-no-autostart` 的启动请求返回 timeout；未盲目重复启动，只读进程查询随后成功，发现 Watch App 进程 PID 508。进程存在不单独证明参数、界面或录音结果。此前同轮的首次安装/启动成功结果另存 `recognition-first-*`，没有覆盖最终超时记录。代理未点击开始翻译。下一步请用户等“麦克风开启 · 直接说话”后说完整短句，记录“原声字幕”与实际英文译音，区分听写错误和翻译错误。

## 截图中的上传积压停止：有界合批（2026-09-27）

- 用户截图显示“网络无法跟上实时语音，已停止录音。”，上方可见原声字幕包含“地铁站怎么走……”。该错误在旧代码中只由 `AsyncStream<Data>.Continuation.yield` 的 `.dropped` 路径产生，说明客户端 20 帧上传队列已满；不是这张图证明了麦克风引擎停止或用户网络差。没有这次会话的逐包时间、设备日志或音频，仍不能确认实际发送速度、识别准确率或翻译效果。
- 旧发送器每次只发送一个 100ms 帧并等待发送完成。新增 `AudioUploadQueue`：独立保存 PCM、单个顺序发送器、最多合并已排队的 300ms 音频；新帧没有积压时立即发送，不等待凑批、不删除静音或词句。唤醒信号允许合并，音频不采用丢帧策略。队列待发送加发送中上限仍为两秒（96,000 字节），入队/取批检查最早音频等待时间；超限停止并显示 `UPLOAD-BACKLOG`，不再未经验证将原因归为网络。手动停止排空已接受帧后才发 stop；后台/失败/服务关闭取消，不跨会话重放。无后续采集的在途 send 仍由原有结束超时兜底，不声称每种卡顿都会恰好两秒内结束。
- 新增八项 Swift 队列测试：新帧即时取出、合批顺序与静音逐字节保留、确定性慢发送模拟、在途与待发总量上限、年龄上限、finish/cancel、非法 PCM/重复发送及合并唤醒。模拟每 100ms 输入、每次发送需 150ms 完成时，旧单帧发送器超过 20 帧积压，新实现完整发出相同字节。这是合成调度测试，不是 Watch 实测速率或模型翻译质量测试。
- 服务端兼容测试先复现：两秒以内积压以最多 300ms 小批补发，会触发原有一秒 token-bucket 突发额度并断开。仅将中继短时突发额度从 48,000 调整为 96,000 字节以匹配客户端上限，每秒补充 48,000 字节、单包/上游积压/并发/鉴权限制均未放宽。新增 mock 测试验证完整两秒补发的字节顺序、stop 在音频之后、超过额度仍拒绝及每 100ms 仅补回 4,800 字节；真实 localhost WebSocket + mock provider 测试改用含静音的 300ms 合并包。未连接真实模型运行这些测试。
- 20 项 XCTest、19 条 Swift smoke 断言、15 项 Node 测试以及 Node 语法检查全部通过。watchOS Debug（签名）和 Release（不签名）构建成功，无编译告警；Debug 严格深度签名校验通过。Release 二进制未含音频/会话/网络调试标识、调试启动参数或批次/积压/发送时长诊断字符串。Debug 只记录受控批次数、字节对应时长和发送耗时，不记录音频、字幕、地址或凭证。
- Xcode 仅为 Watch 目标补充新源文件引用；所有 build configurations 与签名设置和本轮修改前备份逐字相同。未运行项目生成脚本，未修改手机配置、语音处理、云处理同意、前台限制、模型/协议或提示词。
- 已确认隧道当前请求数为零后重启本地中继以加载新限速设置，PID 20990；匿名本地 `/health` 返回 HTTP 200 且 `providerConnectionVerified: false`。这只验证服务进程健康，不证明上游模型成功。服务地址和设备令牌未改，手机无需重新配置。
- 最终 Debug 已成功安装到目标 Apple Watch，安全启动明确返回 success，参数为 `--diagnostics-no-autostart`，PID 516。代理没有点击开始翻译、开启麦克风或发起真实模型会话。安装/启动成功不代表真机持续上传、双向翻译和外放已经验收。
- 证据：`.build/verification/upload-core-tests.log`、`upload-smoke.log`、`upload-server-tests.log`、`upload-relay-before.log`（预期失败的旧突发额度复现）、`upload-watch-debug.log`、`upload-watch-release.log`、`upload-binary-checks.json`、`upload-relay-restart.json`、`upload-install.json`、`upload-launch.json`。原文件备份在 `upload-before/`。Apple 官方 `send(_:completionHandler:)` 与 `AsyncStream.Continuation.yield(_:)` 资料仅用于核对 API；不能据此推断真实 Watch 单次发送耗时。
- 待用户主动测试：点“开始翻译”，保持前台，连续说 10–15 秒中文后播一小段清晰英文，检查是否持续工作、中文转英文和英文转中文能否外放；如停止，保留完整橙色错误及括号标记。仍不能宣称截图故障已在真实语音环境下消除。


## 第二次上传积压反馈与显示时长（2026-09-27）

- 用户新截图仍显示 `UPLOAD-BACKLOG`。前一轮有界合批未在用户实际使用中消除积压，不能把此前测试/安装成功等同于真机修复。截图没有逐包耗时，无法证明唯一根因；本轮未取得故障会话设备日志。
- 原 Watch sender 在 `@MainActor InterpreterSession` 的 `Task` 上排队，可能与字幕更新争用调度。现将相同的串行 WebSocket 上传放到 `Task.detached`，提取 `AudioUploadSender` 用可注入发送函数进行隔离测试；不增加并发发送、不增加两秒上限、不删除静音、不修改模型或协议。UI 更新异步回到 MainActor 并核验会话 ID；取消/后台不重放，不在取消后发送 stop。正常结束仍先排空已接受的 PCM 再发 stop。
- 增加六项 Swift 测试：保留含静音的完整字节及 stop 顺序、取消等待、取消在途发送、人为阻塞 MainActor 后独立发送器仍能排空、传输失败不发送 stop、数值诊断区分排队与在途等待。MainActor 阻塞试验验证隔离设计，不证明原来的真机故障一定来自 UI。
- Debug 的积压错误显示待发/在途毫秒、发送等待、最早音频年龄、已发批数和 active/dimmed/inactive。入队溢出时立即在采集回调取数，避免等待 UI 后才取数掩盖原始状态；不采集音频、字幕、地址或凭证。需要用户下一次主动录音验证实际数值。
- 屏幕：核对 Apple 官方文档后，未采用 iOS 的 `UIApplication.isIdleTimerDisabled`（watchOS 无此 API）、已不再支持的 frontmost timeout 或伪装运动/正念的扩展会话。显式 `WKSupportsAlwaysOnDisplay = true`（watchOS 8 起本来默认开启，不是新解锁“强制常亮”能力）；新增 `isLuminanceReduced` 精简显示及 App 内“屏幕显示设置”说明。低亮度与后台不同，原有真正后台停止策略保留。不能承诺无限全亮、不息屏或息屏持续录音。用户可按 Apple 设置说明开启支持设备的始终显示、允许腕译显示、延长唤醒时长及将腕译返回表盘设为 1 小时；低电量/剧院模式会禁用始终显示。
- 首次 Debug 编译暴露 `DisclosureGroup` 不支持 watchOS；已改用原生 Button 加条件 VStack，并重新构建成功。26 项 XCTest、19 条 Swift smoke、15 项 Node 测试及 Node 语法检查通过。Watch Debug（签名）与 Release（不签名）构建成功，无最终编译告警。Debug 严格深度签名校验成功，Release 未含新增积压/屏幕诊断字符串或调试启动参数。Xcode build configurations / configuration lists 与本轮前备份一致，签名未改。
- 本轮没有改动/重启中继，也没有连接真实模型、点击开始或开启麦克风。安装新 Debug 到 Watch 的命令 40 秒超时；随后按 bundle ID 只读查询已安装 App 也失败。没有盲目再次安装或启动，因此不能确认设备上已有本轮构建，未能做真机界面截图和低亮度验证。请用户解锁手表并让手表、配对手机、Mac 靠近后继续；后续安全启动必须保留 `--diagnostics-no-autostart`。
- 证据：`.build/verification/backlog2-core-tests.log`、`backlog2-smoke.log`、`backlog2-server-tests.log`、`backlog2-watch-debug.log`、`backlog2-watch-release.log`、`backlog2-binary-checks.json`、`backlog2-install.json` 与 `backlog2-installed-state.json`。修改前文件保存在 `backlog2-before/`。官方资料本地副本为 `backlog2-always-on-symbol.txt`、`backlog2-display-guide.txt`、`backlog2-always-on-support.txt`、`backlog2-extended-runtime.md`、`backlog2-frontmost.md`、`backlog2-idle-timer.md`；Web 工具本轮没有返回可引用内容，资料由官方地址直接下载核对。
- 待安装确认后，用户主动在前台连续讲话 10–15 秒并分别测试中译英/英译中；记录抬腕、低亮度与返回表盘时是否停止。如再次积压，应拍下完整错误和新数值，而不是继续调大队列。真机持续上传、识别精度、译音和低亮度下会话行为尚未验收。


## 解锁后重新安装确认（2026-09-27，Mac 本地日期）

- 用户明确回复手表已解锁后，重新执行安装；`backlog2-unlocked-install.json` 明确返回 success，bundle ID 为 `dev.wristinterpreter.prototype.watchkitapp`。本轮未重新修改源代码或构建，安装的是上一轮已测试并通过严格签名校验的 Debug 产物；安装前再次校验签名成功。
- 使用 `--diagnostics-no-autostart` 安全启动成功，`backlog2-unlocked-launch.json` 返回 success，PID 621。未点击开始、未主动开启麦克风或请求真实模型会话。安装及进程启动成功不能证明持续上传、准确识别、双向外放或低亮度下正常运行。
- 设备截图命令成功，保存 `backlog2-unlocked-screen.png`，但图像为全黑，未显示应用 UI；因此不能据此确认界面/字幕布局、屏幕设置或低亮度适配已经真机验收，也不推断全黑的具体原因。没有为拍图而重启会话或变更手表系统设置。
- 下一步由用户抬腕打开腕译并主动点开始，先连续说 10–15 秒中文，再说英文；如再次停止，保留包含待发/在途/发送等待等数值的完整错误截图。屏幕相关系统设置仍需用户按此前说明调整，未承诺强制永久全亮。


## 带数值的第三次积压反馈：解除过小单包上限（2026-09-27，Mac 本地日期）

- 用户截图明确显示：待发 1,700ms、在途 300ms、当前发送等待 565ms、最早 1,999ms、已发 9 批、active。这证明前一轮把发送任务移出 MainActor 尚未在真机消除积压，错误发生时屏幕状态为前台；不能仅凭截图归因于息屏、网络带宽、蓝牙路线、服务器或永久平均发送耗时。565ms 是当前仍未完成的一次 send 的已等待时间，不是 RTT 或所有批次的均值。
- 代码里的 300ms 单包上限加串行 await send 构成可复现吞吐限制：如果每次发送完成经常耗时超过 300ms，即使还有字节容量也无法追上实时输入。本轮只把已有队列的单批合并上限改为中继已支持的一秒 PCM（48,000 字节）；新帧不等待凑批，仍然一批在途、按序发送，静音逐字节保留。总量 96,000 字节与最早年龄两秒保护均未放宽；不引入并发发送或无界缓存。不能由此宣称解决持续物理带宽不足。
- 新回归测试先运行旧实现：模拟输入每 100ms 一帧、每次发送 600ms 完成，3,300ms 时复现 overflow。修复后分别模拟固定 600/750/900ms、200/600/800/450ms 抖动、夹杂一次 1,200ms 停顿的发送序列，连续 30 秒输入及末尾 drain 全字节一致（包含静音），每包不超过一秒、总量不超过两秒、待发/在途最早年龄始终低于两秒。另测一秒单包边界、立即取出不足一秒的余帧，以及持续每包 1,100ms 时仍触发保护，避免以加大单包掩盖真正持续吞吐不足。这些都是合成调度条件，不是实测链路吞吐。
- 修改发送器完整性测试为 15 帧，验证先发送一秒再半秒、stop 在所有音频之后。中继新增两包各一秒在既有两秒突发预算内无损通过的测试；既有持续限速测试仍通过。真实 localhost WebSocket 与本地 mock provider 的往返测试升级为一秒 PCM 包，验证字节、字幕和末尾 stop/output 顺序。没有调用真实翻译模型或测试录音。
- 29 项 Swift XCTest、19 条 Swift smoke、16 项 Node 测试及 Node 语法检查通过。最初默认 Desktop 的 SwiftPM 输出触发资源叉签名错误，改为 `/private/tmp/wrist-interpreter-tests-backlog3` scratch 后取得真实测试失败复现与修复后全绿。Watch Debug（签名）/Release（不签名）编译成功、无最终编译告警；Debug 严格深度签名校验成功；Release 未含调试标识/参数。Xcode 项目文件与修改前逐字相同，签名、模型、协议、提示词、采样、云处理同意、前台保护和屏幕设置均未改变。
- 中继生产源码未修改，不需要重启；未读取或打印 `.env`，未更换地址/令牌。修改前备份在 `backlog3-before/`。本轮 Web 工具检索未返回内容，没有据此引入新的 API 或未经核实的系统行为结论。
- 新 Debug 安装明确 success，随后以 `--diagnostics-no-autostart` 安全启动明确 success，PID 644。未点击开始、主动录音或发起真实模型会话。请用户连续讲话 20–30 秒（然后切换语言），如果再停止保留完整数值截图；实际发送耗时随包大小的变化、连续翻译精度/延迟及外放仍需真机验收，不声称已经根治。
- 证据：`.build/verification/backlog3-repro-before.log`（预期业务失败）、`backlog3-core-tests.log`、`backlog3-smoke.log`、`backlog3-server-tests.log`、`backlog3-server-check.log`、`backlog3-watch-debug.log`、`backlog3-watch-release.log`、`backlog3-binary-checks.json`、`backlog3-install.json`、`backlog3-launch.json`。
