import AVFAudio
import Foundation
import Combine
import WatchKit

@MainActor
final class InterpreterSession: ObservableObject {
    static let shared = InterpreterSession()
    enum Phase: Equatable {
        case idle, connecting, listening, ending, failed(String)
        var isRunning: Bool { self == .connecting || self == .listening || self == .ending }
    }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var captions = TranscriptBuffer()
    @Published private(set) var notice: String?
    @Published private(set) var microphoneReceiving = false
    @Published private(set) var activity: String?
    private let audio = DuplexAudio()
    private var socket: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var receiver: Task<Void, Never>?
    private var sender: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var sessionTimer: Task<Void, Never>?
    private var runtimeSession: WKExtendedRuntimeSession?
    private var uploadQueue: AudioUploadQueue?
    private var currentID = UUID()
    private var interruptObserver: NSObjectProtocol?
    private var consumedLaunch = false
    private var lastDroppedMilliseconds = 0
    private var reconnectAttempts = 0
    private var isReconnecting = false
    #if DEBUG
    private var displayState = "active"
    #endif

    private init() {
        interruptObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
            // .ended means the interruption is over, not that recording stopped.
            // Delivery is on .main; handle synchronously so a queued stale event
            // cannot stop a different session started in the meantime.
            MainActor.assumeIsolated {
                self?.diagnostic(type == .began ? "interruption_began" : "interruption_ended")
                if type == .began, self?.phase.isRunning == true {
                    self?.fail("音频被系统中断，请结束 Siri 或其他音频后重新开始。")
                }
            }
        }
    }

    /// Only a fresh launch or an explicit Siri intent auto-starts. Returning from
    /// the background must not unexpectedly resume a microphone session.
    func startFromLaunchIfNeeded() async {
        guard !consumedLaunch else { return }
        consumedLaunch = true
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--diagnostics-network-check") {
            await checkNetworkWithoutRecording()
            return
        }
        // Allows a developer to verify launch without recording or calling the provider.
        if ProcessInfo.processInfo.arguments.contains("--diagnostics-no-autostart") {
            notice = "已更新录音诊断版，尚未录音；请点“开始翻译”。"
            return
        }
        #endif
        await start()
    }

    #if DEBUG
    /// Checks reachability of OpenAI's Live API without credentials, recording,
    /// or a provider session. An expected HTTP 401 proves transport reachability,
    /// NOT API key validity.
    private func checkNetworkWithoutRecording() async {
        guard !phase.isRunning,
              UserDefaults.standard.bool(forKey: "cloudAudioConsent"),
              ConfigurationStore.shared.configuration?.validatedAPIKey != nil else {
            notice = "网络检查未运行：请先完成配置与云处理同意。"
            print("NETWORK_DIAGNOSTIC skipped_missing_configuration_or_consent")
            return
        }
        let id = UUID()
        currentID = id
        phase = .connecting
        notice = "正在检查连接；不会录音或调用翻译模型。"
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        let session = URLSession(configuration: config)
        urlSession = session
        defer {
            session.invalidateAndCancel()
            if currentID == id { reset(); phase = .idle }
        }
        var request = URLRequest(url: SessionConfiguration.upstreamURL)
        request.networkServiceType = .avStreaming
        request.timeoutInterval = 10
        // Intentionally omit Authorization. OpenAI must reject before opening a session.
        let probe = session.webSocketTask(with: request)
        self.socket = probe
        probe.maximumMessageSize = 4096
        probe.resume()
        let deadline = Task {
            try? await Task.sleep(for: .seconds(10))
            if !Task.isCancelled { probe.cancel(with: .goingAway, reason: nil) }
        }
        defer { deadline.cancel(); probe.cancel(with: .goingAway, reason: nil) }
        do {
            _ = try await probe.receive()
            guard currentID == id else { return }
            notice = "网络检查收到非预期响应，已关闭；未录音。"
            print("NETWORK_DIAGNOSTIC websocket_unexpected_response")
        } catch {
            guard currentID == id else { return }
            let status = (probe.response as? HTTPURLResponse)?.statusCode ?? 0
            print("NETWORK_DIAGNOSTIC websocket_status=\(status) error=\((error as NSError).code)")
            if status == 401 || status == 403 {
                notice = "已到达 OpenAI 服务（预期 HTTP \(status)）。未录音、未调用模型；请点开始翻译实测。"
            } else {
                notice = "语音连接检查失败（HTTP \(status)，错误码 \((error as NSError).code)）。未录音。"
            }
        }
    }
    #endif

    func start() async {
        guard !phase.isRunning else { return }
        guard UserDefaults.standard.bool(forKey: "cloudAudioConsent") else {
            notice = "请先同意云端语音处理。"
            return
        }
        guard let apiKey = ConfigurationStore.shared.configuration?.validatedAPIKey else {
            notice = "请先在 iPhone 配置 OpenAI API Key 并同步到手表。"
            return
        }
        let id = UUID()
        currentID = id
        phase = .connecting
        beginExtendedRuntime() // 会话期间保持前台活跃，防止息屏
        notice = nil
        microphoneReceiving = false
        activity = "正在检查麦克风权限"
        diagnostic("start_requested")
        if isReconnecting { isReconnecting = false } else { captions = TranscriptBuffer() }
        lastDroppedMilliseconds = 0
        guard await DuplexAudio.requestPermission() else {
            if currentID == id { fail("没有麦克风权限，请在系统设置中开启。") }
            return
        }
        guard currentID == id, phase == .connecting else { return }
        activity = "正在激活手表音频"
        do { try await audio.prepareForConnection(sessionID: id) }
        catch {
            if currentID == id, phase == .connecting {
                if let audioError = error as? DuplexAudio.AudioError {
                    fail(audioError.localizedDescription)
                } else {
                    fail("无法激活手表音频会话（错误码 \((error as NSError).code)）。请结束其他音频后重试。")
                }
            }
            return
        }
        guard currentID == id, phase == .connecting else { return }
        activity = "等待翻译服务就绪 · 尚未录音"
        diagnostic("audio_activated_waiting_provider")
        var request = URLRequest(url: SessionConfiguration.upstreamURL)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.networkServiceType = .avStreaming
        request.timeoutInterval = 20
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)
        urlSession = session
        let socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = 1_048_576
        self.socket = socket
        socket.resume()
        // The task buffers this until the handshake completes; a 401 here means
        // a bad key and surfaces through the receiver below.
        guard let startData = try? JSONEncoder().encode(LiveSessionStart()),
              let startText = String(data: startData, encoding: .utf8) else {
            if currentID == id { fail("无法构造会话请求。") }
            return
        }
        do { try await socket.send(.string(startText)) } catch {
            guard currentID == id, phase.isRunning else { return }
            let httpStatus = (socket.response as? HTTPURLResponse)?.statusCode
            self.fail(ConnectionFailure.message(for: error, httpStatus: httpStatus))
            return
        }
        receiver = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    guard let self, self.currentID == id else { return }
                    try await self.receive(message, id: id)
                }
            } catch {
                guard let self, self.currentID == id, self.phase.isRunning else { return }
                let nsError = error as NSError
                // The system tore the socket down (sleep/suspend, network
                // change): ECANCELED, never a service failure. Reconnect
                // silently instead of surfacing a raw code like 89.
                let tornDown = (nsError.domain == NSPOSIXErrorDomain
                                && nsError.code == POSIXErrorCode.ECANCELED.rawValue)
                    || (error as? URLError)?.code == .cancelled
                let httpStatus = (socket.response as? HTTPURLResponse)?.statusCode
                if httpStatus == 401 || httpStatus == 403 {
                    // Bad key: reconnecting is pointless.
                    self.fail(ConnectionFailure.message(for: error, httpStatus: httpStatus))
                    return
                }
                if tornDown {
                    let closeCode = socket.closeCode.rawValue
                    #if DEBUG
                    diagnostic("socket_torn_down close_code=\(closeCode)")
                    #endif
                    if self.phase == .ending {
                        self.reset()
                        self.phase = .idle
                    } else {
                        self.reconnectOrFail(finalMessage: "连接被系统中断，请检查手表网络后重新开始。(诊断 close=\(closeCode))")
                    }
                    return
                }
                self.reconnectOrFail(finalMessage: ConnectionFailure.message(for: error, httpStatus: httpStatus))
            }
        }
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, let self, self.currentID == id, self.phase == .connecting else { return }
            self.fail("翻译服务连接超时。")
        }
    }

    private func receive(_ message: URLSessionWebSocketTask.Message, id: UUID) async throws {
        switch message {
        case .data:
            // Direct Live sessions are JSON-only; ignore binary defensively.
            break
        case .string(let text):
            let event = try JSONDecoder().decode(LiveEvent.self, from: Data(text.utf8))
            switch event.type {
            case "session.started":
                guard phase == .connecting else { return }
                timeout?.cancel()
                activity = "服务已就绪，正在启动麦克风"
                diagnostic("provider_ready")
                sessionTimer = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(InterpreterInstructions.maxSessionSeconds))
                    guard !Task.isCancelled, let self, self.currentID == id, self.phase.isRunning else { return }
                    self.notice = "单次会话时限已到，正在结束。"
                    self.end()
                }
                do { try await startAudio(id: id) }
                catch {
                    if currentID == id {
                        if let audioError = error as? DuplexAudio.AudioError { fail(audioError.localizedDescription) }
                        else { fail("无法启动双向录放音（错误码 \((error as NSError).code)）。") }
                    }
                }
            case "session.output_audio.delta":
                guard phase == .listening || phase == .ending,
                      let base64 = event.delta,
                      let pcm = Data(base64Encoded: base64), !pcm.isEmpty else { return }
                if phase == .listening { activity = "已收到译音 · 正在播放并继续收音" }
                audio.play(pcm)
            case "session.input_transcript.delta":
                if let delta = event.delta { captions.append(delta, to: .source, eventID: event.event_id) }
            case "session.output_transcript.delta":
                if let delta = event.delta { captions.append(delta, to: .translation, eventID: event.event_id) }
            case "session.delegation.created":
                // No tools exist. Fail closed rather than let an interpreter turn into an assistant.
                diagnostic("provider_or_relay_error")
                fail("模型偏离了纯翻译模式，已停止会话。")
            case "error":
                diagnostic("provider_or_relay_error")
                fail(event.error?.message ?? "翻译服务发生错误。")
            case "session.closed":
                phase = .ending
                microphoneReceiving = false
                activity = "服务已结束，正在播放剩余译音"
                diagnostic("server_closed")
                timeout?.cancel()
                uploadQueue?.cancel()
                sender?.cancel()
                audio.stopCapture()
                await audio.drainAndStop()
                if currentID == id { reset(); phase = .idle }
            default: break
            }
        @unknown default: break
        }
    }

    private func startAudio(id: UUID) async throws {
        let queue = AudioUploadQueue()
        uploadQueue = queue
        guard let socket else { throw URLError(.networkConnectionLost) }
        // Capturing the socket and queue for this session keeps the actual upload
        // independent of MainActor, even while SwiftUI is rendering captions.
        sender = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try await AudioUploadSender.run(queue: queue, sendAudio: { bytes in
                    let payload = ["type": "session.input_audio.append",
                                   "audio": bytes.base64EncodedString()] as [String: String]
                    let data = try JSONSerialization.data(withJSONObject: payload)
                    guard let text = String(data: data, encoding: .utf8) else {
                        throw URLError(.cannotParseResponse)
                    }
                    try await socket.send(.string(text))
                }, finishInput: {
                    try await socket.send(.string(#"{"type":"session.close"}"#))
                }, onProgress: { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.currentID == id else { return }
                        let droppedTotal = queue.diagnostics().droppedMilliseconds
                        let newlyDropped = droppedTotal - self.lastDroppedMilliseconds
                        self.lastDroppedMilliseconds = droppedTotal
                        if newlyDropped > 0 {
                            self.notice = "网络跟不上，跳过 \(String(format: "%.1f", Double(newlyDropped) / 1000.0)) 秒语音；会话继续。"
                        }
                        if progress.batches == 1, self.phase == .connecting || self.phase == .listening {
                            self.microphoneReceiving = true
                            self.activity = "语音已上传 · 等待译文"
                            self.diagnostic("first_audio_uploaded")
                        }
                        #if DEBUG
                        self.diagnostic("audio_uploaded_batches=\(progress.batches) batch_ms=\(progress.batchMilliseconds) backlog_ms=\(progress.backlogMilliseconds) send_ms=\(progress.sendMilliseconds)")
                        #endif
                    }
                })
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self, self.currentID == id, self.phase.isRunning else { return }
                    self.reconnectOrFail(finalMessage: "音频上传失败，已停止录音。")
                }
            }
        }
        try await audio.start(sessionID: id, onFrame: { [weak self] bytes in
            switch queue.enqueue(bytes) {
            case .accepted, .closed: break
            case .overflow:
                // Transient: the queue already skipped stale audio and stays
                // live; the drop notice surfaces via upload progress.
                Task { @MainActor in
                    if self?.currentID == id { self?.notice = "网络繁忙，正在跳过积压语音…" }
                }
            case .invalidFrame:
                Task { @MainActor in
                    if self?.currentID == id { self?.fail("录音数据格式异常，已停止录音。（UPLOAD-FORMAT）") }
                }
            }
        }, onFailure: { [weak self] message in
            Task { @MainActor in
                if self?.currentID == id { self?.fail(message) }
            }
        })
        guard currentID == id, phase == .connecting else { return }
        phase = .listening
        reconnectAttempts = 0
        diagnostic("audio_engine_started")
        // Avoid a nonessential system haptic at the exact moment capture starts.
    }

    func end() {
        guard phase.isRunning else { return }
        if phase == .connecting { reset(); phase = .idle; return }
        guard phase != .ending else { return }
        phase = .ending
        microphoneReceiving = false
        activity = "录音已停止，等待剩余译音"
        diagnostic("user_stopped")
        audio.stopCapture()
        uploadQueue?.finish()
        let id = currentID
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, self.currentID == id, self.phase == .ending else { return }
            self.fail("结束超时，已关闭录音和连接；末尾译文可能未播放完。")
        }
    }

    func backgrounded() {
        guard phase.isRunning else { return }
        diagnostic("background_stopped")
        reset()
        phase = .idle
        notice = "原型离开前台即停止；返回后请主动开始。"
    }

    func configurationChanged() {
        guard phase.isRunning else { return }
        diagnostic("configuration_stopped")
        reset()
        phase = .idle
        notice = "授权或服务配置已更改，录音已停止；请确认后重新开始。"
    }

    func displayChanged(isActive: Bool, isDimmed: Bool) {
        #if DEBUG
        displayState = isDimmed ? "dimmed" : (isActive ? "active" : "inactive")
        diagnostic("display_state=\(displayState)")
        #endif
    }

    private func fail(_ message: String) {
        diagnostic("session_failed")
        notice = nil
        reset()
        phase = .failed(message)
    }

    /// Transport died mid-session (not auth, not user action): silently
    /// re-establish up to 3 times, then surface the failure. Captions and
    /// consent survive; the mic restarts with a brief gap.
    private func reconnectOrFail(finalMessage: String) {
        guard phase == .listening else { fail(finalMessage); return }
        reconnectAttempts += 1
        guard reconnectAttempts <= 3 else {
            reconnectAttempts = 0
            fail(finalMessage)
            return
        }
        diagnostic("reconnect_attempt=\(reconnectAttempts)")
        notice = "连接中断，正在重连…"
        // Keep the extended runtime session alive across the reconnect:
        // tearing it down here used to let the system suspend the app
        // mid-session (black screen after a couple of sentences).
        reset(keepExtendedRuntime: true)
        phase = .idle
        isReconnecting = true
        Task { [weak self] in await self?.start() }
    }

    private func diagnostic(_ event: String) {
        #if DEBUG
        // Controlled stage names/counts only: no audio, transcripts, tokens or URLs.
        print("SESSION_DIAGNOSTIC \(event)")
        #endif
    }

    /// Keep the app foreground-active for the whole session so the screen
    /// does not sleep mid-translation. Ended in reset() unless the reset is
    /// part of an auto-reconnect (the keep-alive must survive reconnects —
    /// invalidating it mid-session lets the system suspend the app and the
    /// screen goes black).
    private func beginExtendedRuntime() {
        guard runtimeSession == nil else { return }
        let rs = WKExtendedRuntimeSession()
        runtimeSession = rs
        rs.start()
    }

    private func endExtendedRuntime() {
        runtimeSession?.invalidate()
        runtimeSession = nil
    }

    private func reset(keepExtendedRuntime: Bool = false) {
        microphoneReceiving = false
        activity = nil
        isReconnecting = false
        currentID = UUID()
        timeout?.cancel()
        sessionTimer?.cancel()
        if !keepExtendedRuntime { endExtendedRuntime() }
        uploadQueue?.cancel()
        uploadQueue = nil
        sender?.cancel()
        receiver?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        urlSession?.invalidateAndCancel()
        socket = nil
        urlSession = nil
        audio.stop()
    }

    private struct LiveEvent: Decodable {
        let type: String
        var event_id: String?
        /// Base64 PCM for output_audio deltas, transcript text for transcript deltas.
        var delta: String?
        var error: LiveError?
        struct LiveError: Decodable { var message: String? }
    }

    /// Sent once per connection, right after the WebSocket handshake.
    private struct LiveSessionStart: Encodable {
        let type = "session.start"
        let event_id = "start_interpreter"
        struct Session: Encodable {
            let model = InterpreterInstructions.model
            let instructions = InterpreterInstructions.prompt
            struct Audio: Encodable {
                struct Format: Encodable { let type = "audio/pcm"; let rate = 24_000 }
                struct Output: Encodable { let voice = InterpreterInstructions.voice }
                let format = Format()
                let output = Output()
            }
            struct Delegation: Encodable { let type = "client" }
            let audio = Audio()
            let delegation = Delegation()
            let store = false
        }
        let session = Session()
    }
}
