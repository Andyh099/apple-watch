import SwiftUI

@main
struct WristInterpreterPhoneApp: App {
    var body: some Scene { WindowGroup { SettingsView() } }
}

struct SettingsView: View {
    @ObservedObject private var store = ConfigurationStore.shared
    @State private var endpoint = ""
    @State private var token = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("中英双向 · 直接口译", systemImage: "waveform")
                    Text("在手表上开始会话，听到中文译成英文，听到英文译成中文。本机只配置服务，不采集语音。")
                        .font(.subheadline).foregroundStyle(.secondary)
                } header: { Text("腕译 · 工程原型") }
                Section {
                    TextField("wss://你的服务域名/interpret", text: $endpoint)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    SecureField("开发设备令牌（不是 OpenAI API Key）", text: $token)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("保存并同步到手表") {
                        do {
                            try store.save(SessionConfiguration(endpoint: endpoint.trimmingCharacters(in: .whitespacesAndNewlines), token: token))
                            error = nil
                        } catch { self.error = error.localizedDescription }
                    }
                    Text(store.status).font(.footnote).foregroundStyle(.secondary)
                    if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                } header: { Text("开发连接") } footer: {
                    Text("需要带有效证书的加密服务地址。服务商 API Key 只能放在后端。当前设备令牌仅供开发测试；尚未实现账号、配对码或订阅系统。")
                }
                Section("隐私与验证边界") {
                    Text("开始前，手表会单独请求麦克风权限和云端处理同意。声音会经你配置的服务发送至 OpenAI。此原型不主动保存音频、字幕或翻译历史；不代表服务商不保留数据。")
                    Text("当前是双向连续语音验证版本，不承诺同传延迟、语气复刻、扬声器回声消除或后台持续工作。请先告知参与对话的人，并仅使用非敏感测试内容。")
                    Text("订阅与支付尚未实现。本原型不会发起购买，也没有虚构的会员权益。")
                }.font(.footnote)
            }
            .navigationTitle("腕译设置")
            .task {
                endpoint = store.configuration?.endpoint ?? ""
                token = store.configuration?.token ?? ""
            }
        }
    }
}
