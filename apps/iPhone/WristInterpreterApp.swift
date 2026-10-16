import SwiftUI
import Speech

@main
struct WristInterpreterPhoneApp: App {
    var body: some Scene { WindowGroup { SettingsView() } }
}

struct SettingsView: View {
    @ObservedObject private var store = ConfigurationStore.shared
    @State private var apiKey = ""
    @State private var error: String?
    @State private var languagePair: LanguagePair = ConfigurationStore.shared.languagePair
    @State private var engineMode: EngineMode = ConfigurationStore.shared.engineMode
    @State private var packReady: Bool?
    @State private var speechAuth: SFSpeechRecognizerAuthorizationStatus = SFSpeechRecognizer.authorizationStatus()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("\(languagePair.displayName)双向 · \(engineMode.displayName)", systemImage: "waveform")
                    Text("在手表上开始会话，自动识别说话语言并译成另一种，无需手动切换。本机只配置密钥，不采集语音。")
                        .font(.subheadline).foregroundStyle(.secondary)
                } header: { Text("腕译 · 工程原型") }

                Section {
                    Picker("翻译语言对", selection: $languagePair) {
                        ForEach(LanguagePair.allCases, id: \.self) { pair in
                            Text(pair.displayName).tag(pair)
                        }
                    }
                    .onChange(of: languagePair) { _, _ in
                        store.setLanguagePair(languagePair)
                        Task { await refreshPackStatus() }
                    }
                    Picker("翻译引擎", selection: $engineMode) {
                        ForEach(EngineMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .onChange(of: engineMode) { _, _ in
                        store.setEngineMode(engineMode)
                        Task { await refreshPackStatus() }
                    }
                    Text("在线直连：手表直连 OpenAI，实时同传，需联网。离线手机中转：手表录音经蓝牙发手机，手机端侧识别+翻译（苹果离线模型），不联网。")
                        .font(.footnote).foregroundStyle(.secondary)
                } header: { Text("语言与引擎") }

                if engineMode == .offline {
                    Section {
                        if #available(iOS 26, *) {
                            Button("请求语音识别权限") {
                                SFSpeechRecognizer.requestAuthorization { _ in
                                    DispatchQueue.main.async {
                                        speechAuth = SFSpeechRecognizer.authorizationStatus()
                                    }
                                }
                            }
                            Text("语音识别：\(speechAuthText)")
                                .font(.footnote).foregroundStyle(.secondary)
                            if let ready = packReady {
                                Label(ready ? "离线语言包已就绪" : "离线语言包未下载",
                                      systemImage: ready ? "checkmark.circle.fill" : "exclamationmark.circle")
                                    .foregroundStyle(ready ? .green : .orange)
                            }
                            Text("首次使用前，请在 iPhone 的翻译 App 里下载「中文」「英语」「西班牙语」的离线包（翻译 App 下过的包，本 App 可直接用）。另建议在「设置 → 通用 → 键盘 → 听写语言」下载同样三种语言，以启用端侧听写。")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else {
                            Text("离线翻译需要 iOS 26 及以上系统，当前系统不支持。")
                                .foregroundStyle(.orange)
                        }
                    } header: { Text("离线引擎") } footer: {
                        Text("离线连续翻译：手表上点开始后直接说话，自动分句、逐句翻译外放；点结束停止。手机需在蓝牙范围内。")
                    }
                }

                Section {
                    SecureField("OpenAI API Key", text: $apiKey)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("保存并同步到手表") {
                        do {
                            try store.save(SessionConfiguration(apiKey: apiKey))
                            error = nil
                        } catch { self.error = error.localizedDescription }
                    }
                    Text(store.status).font(.footnote).foregroundStyle(.secondary)
                    if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                } header: { Text("在线直连配置") } footer: {
                    Text("手表直连 OpenAI，不再经过 Mac 中转。Key 保存在本机和手表的钥匙串中，经系统加密通道同步；不会显示或记录。建议在 OpenAI 后台设置用量上限。")
                }
                Section("隐私与验证边界") {
                    Text("开始前，手表会单独请求麦克风权限和云端处理同意。在线模式下声音会直接发送至 OpenAI；离线模式下语音只在手机本地处理，不联网。此原型不主动保存音频、字幕或翻译历史；不代表服务商不保留数据。")
                    Text("当前是双向连续语音验证版本，不承诺同传延迟、语气复刻、扬声器回声消除或后台持续工作。请先告知参与对话的人，并仅使用非敏感测试内容。")
                    Text("订阅与支付尚未实现。本原型不会发起购买，也没有虚构的会员权益。")
                }.font(.footnote)
            }
            .navigationTitle("腕译设置")
            .task {
                // Never fill the key back into the field; it lives in the Keychain.
                apiKey = ""
                languagePair = store.languagePair
                engineMode = store.engineMode
                await refreshPackStatus()
            }
        }
    }

    private var speechAuthText: String {
        switch speechAuth {
        case .authorized: return "已允许"
        case .denied: return "已拒绝（去设置里打开）"
        case .restricted: return "受限制"
        case .notDetermined: return "未请求"
        @unknown default: return "未知"
        }
    }

    private func refreshPackStatus() async {
        guard engineMode == .offline else { return }
        if #available(iOS 26, *) {
            packReady = await OfflineTranslationEngine.shared.packReady(pair: languagePair)
        } else {
            packReady = false
        }
    }
}
