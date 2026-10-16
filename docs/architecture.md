# 架构与技术边界

记录日期：2026-09-27。此文区分已写入的代码、官方 API 文档描述和待实验验证的产品效果。

## 数据流

```text
Siri / 手表应用入口
  → 前台 Watch 会话：授权 + 麦克风权限
  → AVAudioEngine：输入转换为 24 kHz / mono / PCM16 LE
  → 每 100 ms 一帧（静音也发送）
  → WSS wss://api.openai.com/v1/live/sessions：手表直连，走手表 Wi-Fi 或蜂窝
  → GPT-Live /v1/live/sessions：Authorization 即 API Key，固定翻译指令
  → 输出 PCM (base64) + 原声/译文文本增量
  → Watch：流式播放 + 有界滚动字幕

iPhone → Keychain + WatchConnectivity → 手表 API Key
```

手机不是音频中转站，不提供录音/翻译页面。2026-10-15 起默认直连：不再需要 Mac 中继与临时公网通道；`server/` 保留为旧实现。代价是 API Key 落在手表钥匙串——建议在 OpenAI 后台设置用量上限。

手机不是音频中转站，不提供录音/翻译页面。已配置的手表由自己的网络栈访问中继；实际网络可达性与音频路线待真机确认。

## 模型选择不是能力承诺

官方文档区分：

- **专用 Realtime translation**：翻译会话持续接收音频并输出译文；会话配置包含目标输出语言。
- **GPT-Live**：双工语音交互，可边听边说；它是会话模型，不因用了双工接口就天然成为准确的双向同传。

当前代码选择第二条作为实验适配器：推断当前短语语言、翻译到另一语言、禁止开场白/附和/回答问题/工具操作、保持说话人语气。客户端不提供自定义模型指令入口。

**没有实现**专用翻译模型的语言路由和多方向会话。不能简单把同一条混合麦克风音频发送到两个翻译会话再叠加播放，那不能证明正确归属与去重。若 GPT-Live 实测不能稳定纯翻译，这条适配器应被替换或重新设计，不把指令遵循当成保证。

## 会话协议（手表直连，2026-10-15 起）

手表向 OpenAI：

1. WebSocket 打开后发送 `session.start`；固定模型、音频格式、声音和翻译指令，`delegation.type = client`、`store = false`。
2. 等待 `session.started`，然后通知手表 `ready`；尚未 ready 不允许音频上行。
3. 输入为 `session.input_audio.append`，输出音频为 `session.output_audio.delta`；文本来自输入/输出 transcript delta。
4. 用户结束时停止录音、完成待发送帧、发送 `session.close`。接受末尾音频直到 `session.closed`，手表随后排空本地播放队列。
5. 不执行任何委派；遇到 `session.delegation.created` 停止会话并报告偏离翻译模式。

不发送 assistant greeting，也不通过字符过滤粗暴删除“好的”（原话确有“好的”时应翻译）。模型自己输出多余内容只能靠真实测试发现，提示词测试不证明其不存在。

手表协议只接受二进制 PCM 或 `{"type":"stop"}` 控制命令。中继返回 `ready` / `caption` / `notice` / `error` / `closed` 及二进制音频。文本顺序与音频相邻不等于逐词对齐；UI 没有伪造句对、说话人身份或逐词时间线。

## 音频和生命周期

- watchOS 音频网络启动顺序：云处理同意与麦克风授权 → 等待异步 `AVAudioSession.activate` 成功 → 建立 WebSocket → 等待中继 `ready` → 开始引擎采集。网络连接前仅准备音频路线，不安装输入 tap；不得等 ready 才首次激活音频。同步 `setActive(true)` 的上一版仍在真机报 -1009；不能把无异常返回当成音频网络已获准。
- AVAudioEngine 输入启用系统语音处理，无法启用时显式失败，不暗中切换到轮流录音。
- 播音时不静音采集。是否能在目标手表扬声器上可靠消除回声，需要真实声学测试；API 存在不等于每条路线可用。
- 上传使用脱离 UI MainActor 的单个顺序发送器（`Task.detached` + `AudioUploadSender`），网络发送不等待字幕渲染；仅首批、每 25 批或慢发送时异步投递受会话 ID 保护的 UI/Debug 更新：采集仍为 100ms 帧，只合并已经排队的相邻帧，每批最多 1 秒（中继现有单包上限）；没有积压时立即发送，不等待凑满、不丢弃静音。独立音频队列的待发送与发送中数据合计最多两秒（96,000 字节），入队/取批时检查最早音频等待时间低于两秒，超限显式停止；唤醒信号可合并，但音频不能静默丢弃。结束按钮会先排空已接受的帧再发送 stop；取消/后台/失败丢弃队列，不重放。发送中卡顿由后续入队检查触发保护，手动结束后仍有整体 15 秒超时。
- 合批上限是单包容量，不是等待计时器：队列只有 100ms 时立即发送 100ms；若发送期间积压 600ms，则下一包立即合并这 600ms。旧 300ms 上限在单次发送经常超过 300ms 时吞吐必然不足；扩大至现有服务端 1 秒包限制改善有界发送开销，不解决持续带宽不足，仍保留两秒总量和最早音频年龄保护。
- 中继上传限速保持每秒 48,000 字节补充额度；短时突发额度为两秒，与客户端最大积压对齐，以允许短暂停顿后的有界补发。单包长度限制不变，客户端每批最多 48,000 字节。该额度不表示允许持续超实时速率或无限追赶延迟。
- 播放排队最多约三秒，积压过大终止而不是延迟无限增长。
- 结束/断线/撤回授权/变更配置/进入后台会关闭相应会话；不自动重连或重放已有录音。
- 为音频流网络声明 `UIBackgroundModes = [audio]`，请求使用 `.avStreaming`；仍在进入后台时主动停止。当前产品只在前台运行，未验收或支持息屏后台、扩展运行会话或电话中继续收音。
- 屏幕由 watchOS 管理，App 不能使用 iPhone 的 idle-timer API 强制永久全亮。显式支持 Always On；`isLuminanceReduced` 时显示精简状态及最近 160 字译文（无译文时显示原声），不因此自动停止或重启会话。系统真正进入后台时仍停止录音。硬件支持、用户“始终显示 / 显示 App”设置、低电量/剧院模式及返回表盘时间均会影响显示；这些设置必须由用户调整，不能承诺不息屏或锁屏持续翻译。未使用运动/正念会话规避系统限制。
- Debug 上传积压错误包含待发/在途音频毫秒、发送等待、最早音频年龄、成功批数与屏幕状态；溢出时在采集回调立即快照，便于区分发送卡顿和 UI 调度，不能单凭错误名归因于网络。Release 不含这些诊断字符串；诊断不记录声音、字幕、地址或凭证。
- 目前手动结束可能丢弃不足一帧的输入残留（最多约 100 ms，另有设备转换缓冲）；末字应在验收中重点检查。服务端测试的“final drain”仅覆盖**已经发送**的 PCM 和模型末尾输出，不证明麦克风末字完整。
- 字幕按增量原样连接，原声/译文分别保留最近 1,200 个字符，事件 ID 去重窗口 512 条。

## 安全与隐私

- OpenAI 项目 Key 只在服务端 `.env`；移动端只有开发设备令牌。
- WSS 强制、禁止 URL 中附带用户名/密码/查询串/片段；拒绝令牌中的控制字符。
- 开发中继默认只监听 localhost；需要外部可信 TLS 代理。
- 令牌恒定时间比较、拒绝浏览器 Origin、限制音频包和速率、限定并发与会话时长。
- 不把上游错误原文转发给设备，防止配置泄漏；无音频/文本访问日志。
- 默认五分钟一次会话、最多一个并发；不是防滥用/计费系统的完整替代。
- 手机上的配置更新通过 WatchConnectivity 发送，凭证保存在各自设备 Keychain；改服务地址后重新征求手表云处理同意。
- 初版没有提供语音“停止”的操作命令：说出的“停止翻译”也当源语言翻译。UI“结束翻译”是明确停止控制，避免他人话语改变系统行为。

## 已查阅的官方资料

以下为本次实现时查阅的官方页面，不意味着模型权限或产品效果已实测；原生代码现已构建通过，见 verification.md：

- [Realtime translation](https://developers.openai.com/api/docs/guides/realtime-translation)：专用翻译会话、目标语言、连续音频输入。
- [Getting started with GPT-Live](https://developers.openai.com/api/docs/guides/live)：双工与委派模型。
- [Voice WebSockets — Live](https://developers.openai.com/api/docs/guides/voice-websockets?api=live)：连接、事件、PCM 格式及本地播放队列。
- [Prompting GPT-Live](https://developers.openai.com/api/docs/guides/live-prompting)：会话指令与 backchannel 行为。
- [Managing Live sessions](https://developers.openai.com/api/docs/guides/live-conversations)：字幕和关闭会话。
- [Apple TN3135: Low-level networking on watchOS](https://developer.apple.com/documentation/technotes/tn3135-low-level-networking-on-watchos)：真实手表的低层网络限制。
- [WWDC2019 Session 716](https://developer.apple.com/videos/play/wwdc2019/716/)：音频会话激活后才能使用相关 WebSocket/流式网络 API；模拟器不能证明真机可用。
- [AVAudioSession.activate](https://developer.apple.com/documentation/avfaudio/avaudiosession/activate(options:completionhandler:))：等待异步音频激活完成后再建立流式连接。
- [UIBackgroundModes](https://developer.apple.com/documentation/bundleresources/information-property-list/uibackgroundmodes)：音频流 background-mode 声明；不代表应用必须持续后台录音。
- [AVAudioIONode.setVoiceProcessingEnabled](https://developer.apple.com/documentation/avfaudio/avaudioionode/setvoiceprocessingenabled(_:))：I/O 节点语音处理 API。
- [AppIntent.supportedModes](https://developer.apple.com/documentation/appintents/appintent/supportedmodes)：前台/后台 intent 执行模式。

- [Apple: Always On](https://support.apple.com/en-us/105074)：支持的硬件、低电量/剧院模式限制与显示 App 设置。
- [Apple Watch display settings](https://support.apple.com/guide/watch/adjust-the-display-settings-apd127ec93ac/watchos)：唤醒时长、始终显示、逐 App 返回表盘时间。
- [SwiftUI isLuminanceReduced](https://developer.apple.com/documentation/swiftui/environmentvalues/isluminancereduced)：低亮度状态检测；并非强制常亮 API。
- [Using extended runtime sessions](https://developer.apple.com/documentation/watchkit/using-extended-runtime-sessions)：限定用途且可在屏幕关闭后运行，不作为翻译应用强制亮屏方案。

不要在未重新评估协议的情况下，仅修改模型名就认为换好了翻译引擎。
