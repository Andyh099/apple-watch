import SwiftUI

@main
struct WristInterpreterWatchApp: App {
    var body: some Scene { WindowGroup { InterpreterView() } }
}

struct InterpreterView: View {
    @ObservedObject private var session = InterpreterSession.shared
    @ObservedObject private var configuration = ConfigurationStore.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @AppStorage("cloudAudioConsent") private var consent = false
    @State private var pendingSiriStart = false
    @State private var showingDisplaySettings = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                // 顶栏：连接状态常驻一行
                HStack(spacing: 6) {
                    Image(systemName: session.phase == .listening ? "waveform" : "waveform.slash")
                        .foregroundStyle(session.phase == .listening ? Color.green : Color.gray)
                    Text(status).font(.caption2).foregroundStyle(.secondary)
                }
                if isLuminanceReduced {
                    // Always On is system-controlled. Reduce work and keep a
                    // readable recent caption without pretending to prevent sleep.
                    Text("低亮度显示 · 抬腕可操作").font(.caption2).foregroundStyle(.secondary)
                    if consent {
                        Text(String((session.captions.translation.isEmpty ? session.captions.source : session.captions.translation).suffix(160)))
                            .font(.body).foregroundStyle(.secondary)
                    }
                } else if !consent {
                    Text("声音将直接发送至 OpenAI 处理。本原型不主动保存录音或字幕。请先告知对话参与者。")
                        .font(.footnote)
                    if configuration.configuration != nil {
                        Text("已配置 OpenAI 直连").font(.caption2).foregroundStyle(.secondary)
                    }
                    Button("同意并开始") {
                        consent = true
                        Task { await session.start() }
                    }.buttonStyle(.borderedProminent)
                } else {
                    // 字幕区：原声小字在上，译文大字在下
                    if !session.captions.source.isEmpty {
                        Text(session.captions.source)
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if !session.captions.translation.isEmpty {
                        Text(session.captions.translation)
                            .font(.title2).fontWeight(.medium)
                    } else if session.captions.source.isEmpty {
                        Text(session.phase == .listening ? "请直接说话…" : "点开始翻译后直接说话")
                            .font(.body).foregroundStyle(.tertiary)
                    }
                    if session.phase.isRunning, let activity = session.activity {
                        Text(activity).font(.caption2).foregroundStyle(.secondary)
                            .padding(.top, 4)
                    }
                    if let notice = session.notice { Text(notice).font(.caption2).foregroundStyle(.orange) }
                    if case .failed(let message) = session.phase { Text(message).font(.caption2).foregroundStyle(.orange) }
                    if session.phase.isRunning {
                        Button(session.phase == .ending ? "正在结束…" : "结束翻译", role: .destructive) { session.end() }
                            .disabled(session.phase == .ending)
                    } else {
                        Button("开始翻译") { Task { await session.start() } }.buttonStyle(.borderedProminent)
                        HStack {
                            Button("撤回云端处理同意", role: .destructive) { consent = false }.font(.caption2)
                            Spacer()
                            Button(showingDisplaySettings ? "收起显示设置" : "屏幕显示设置") {
                                showingDisplaySettings.toggle()
                            }.font(.caption2)
                        }
                        if showingDisplaySettings {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("系统控制屏幕亮度，本 App 不能强制一直全亮。")
                                Text("手表设置 → 显示与亮度 → 始终显示 → 显示 App，允许腕译显示。若没有“始终显示”，当前设备不支持该功能。")
                                Text("唤醒时长可选较长档；通用 → 返回表盘，可为腕译选择 1 小时。低电量和剧院模式会关闭始终显示。")
                                Text("变暗不等于停止；离开 App 进入后台仍会结束翻译。")
                            }.font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }.padding(.horizontal, 2)
        }
        .onReceive(NotificationCenter.default.publisher(for: .startInterpreter)) { _ in
            pendingSiriStart = true
            if scenePhase == .active {
                pendingSiriStart = false
                Task { await session.start() }
            }
        }
        .task {
            session.displayChanged(isActive: scenePhase == .active, isDimmed: isLuminanceReduced)
            if scenePhase == .active { await session.startFromLaunchIfNeeded() }
        }
        .onChange(of: consent) { _, value in
            if !value { session.configurationChanged() }
        }
        .onChange(of: configuration.configuration) { _, _ in
            session.configurationChanged()
        }
        .onChange(of: isLuminanceReduced) { _, value in
            session.displayChanged(isActive: scenePhase == .active, isDimmed: value)
        }
        .onChange(of: scenePhase) { _, value in
            session.displayChanged(isActive: value == .active, isDimmed: isLuminanceReduced)
            if value == .background { session.backgrounded() }
            if value == .active {
                if pendingSiriStart {
                    pendingSiriStart = false
                    Task { await session.start() }
                } else {
                    Task { await session.startFromLaunchIfNeeded() }
                }
            }
        }
    }

    private var status: String {
        switch session.phase {
        case .idle: return configuration.configuration == nil ? "请先在 iPhone 完成配置" : "准备就绪"
        case .connecting: return "正在连接 · 尚未录音"
        case .listening: return session.microphoneReceiving ? "麦克风开启 · 直接说话" : "正在等待麦克风音频"
        case .ending: return "录音已停止 · 播放剩余译文"
        case .failed: return "会话已停止"
        }
    }
}
