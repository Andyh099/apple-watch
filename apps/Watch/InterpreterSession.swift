import AVFAudio
import Foundation
import Combine

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
    private var uploadQueue: AudioUploadQueue?
    private var currentID = UUID()
    private var interruptObserver: NSObjectProtocol?
    private var consumedLaunch = false
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
    /// Checks the configured relay without credentials, recording, or a provider session.
    /// An expected HTTP 401 proves transport reachability, NOT device-token validity.
    private func checkNetworkWithoutRecording() async {
        guard !phase.isRunning,
              UserDefaults.standard.bool(forKey: "cloudAudioConsent"),
              let url = ConfigurationStore.shared.configuration?.validatedURL,
              var health = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
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
        health.scheme = "https"
        health.path = "/health"
        guard let healthURL = health.url else { return }
        do {
            let (_, response) = try await session.data(from: healthURL)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            print("NETWORK_DIAGNOSTIC https_status=\(status)")
            guard currentID == id else { return }
            notice = "HTTPS 检查 HTTP \(status)；正在检查语音连接。"
        } catch {
            guard currentID == id else { return }
            print("NETWORK_DIAGNOSTIC https_error=\((error as NSError).code)")
            notice = "HTTPS 检查失败（错误码 \((error as NSError).code)）；正在检查语音连接。"
        }
        guard currentID == id else { return }
        do {
            try await audio.prepareForConnection(sessionID: id)
        } catch {
            guard currentID == id else { return }
            notice = "网络检查：音频激活失败（错误码 \((error as NSError).code)）。未录音。"
            print("NETWORK_DIAGNOSTIC audio_activation_error=\((error as NSError).code)")
            return
        }
        guard currentID == id else { return }
        print("NETWORK_DIAGNOSTIC audio_activation=success capture=off")
        var request = URLRequest(url: url)
        request.networkServiceType = .avStreaming
        request.timeoutInterval = 10
        // Intentionally omit Authorization. The relay must reject before opening upstream.
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
            if status == 401 {
                notice = "语音连接已到达服务（预期 HTTP 401）。未录音、未调用模型；请点开始翻译实测。"
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
        guard let configuration = ConfigurationStore.shared.configuration, let url = configuration.validatedURL else {
            notice = "请先在 iPhone 配置翻译服务并同步到手表。"
            return
        }
        let id = UUID()
        currentID = id
        phase = .connecting
        notice = nil
        microphoneReceiving = false
        activity = "正在检查麦克风权限"
        diagnostic("start_requested")
        captions = TranscriptBuffer()
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
        var request = URLRequest(url: url)
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        request.networkServiceType = .avStreaming
        request.timeoutInterval = 20
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)
        urlSession = session
        let socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = 256_000
        self.socket = socket
        socket.resume()
        receiver = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    guard let self, self.currentID == id else { return }
                    try await self.receive(message, id: id)
                }
            } catch {
                guard let self, self.currentID == id, self.phase.isRunning else { return }
                let httpStatus = (socket.response as? HTTPURLResponse)?.statusCode
                self.fail(ConnectionFailure.message(for: error, httpStatus: httpStatus))
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
        case .data(let bytes):
            if phase == .listening || phase == .ending {
                if phase == .listening { activity = "已收到译音 · 正在播放并继续收音" }
                audio.play(bytes)
            }
        case .string(let text):
            let event = try JSONDecoder().decode(ServerEvent.self, from: Data(text.utf8))
            switch event.type {
            case "ready":
                guard phase == .connecting, event.sampleRate == 24_000, event.channels == 1, event.format == "pcm16" else {
                    fail("服务端音频配置不兼容。")
                    return
                }
                timeout?.cancel()
                activity = "服务已就绪，正在启动麦克风"
                diagnostic("provider_ready")
                do { try await startAudio(id: id) }
                catch {
                    if currentID == id {
                        if let audioError = error as? DuplexAudio.AudioError { fail(audioError.localizedDescription) }
                        else { fail("无法启动双向录放音（错误码 \((error as NSError).code)）。") }
                    }
                }
            case "caption":
                if let channel = event.channel.flatMap(TranscriptChannel.init(rawValue:)), let delta = event.delta {
                    captions.append(delta, to: channel, eventID: event.eventID)
                }
            case "notice": notice = event.message
            case "error":
                diagnostic("provider_or_relay_error")
                fail(event.message ?? "翻译服务发生错误。")
            case "closed":
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
                    try await socket.send(.data(bytes))
                }, finishInput: {
                    try await socket.send(.string("{\"type\":\"stop\"}"))
                }, onProgress: { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.currentID == id else { return }
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
                let isBacklog = (error as? AudioUploadQueue.Failure) == .backlog
                await MainActor.run { [weak self] in
                    guard let self, self.currentID == id, self.phase.isRunning else { return }
                    if isBacklog { self.uploadBacklogged(queue.diagnostics()) }
                    else { self.fail("音频上传失败，已停止录音。") }
                }
            }
        }
        try await audio.start(sessionID: id, onFrame: { [weak self] bytes in
            switch queue.enqueue(bytes) {
            case .accepted, .closed: break
            case .overflow:
                // Take the snapshot on the capture queue, before a delayed UI
                // callback can distort the observed send wait or backlog age.
                let diagnostics = queue.diagnostics()
                Task { @MainActor in
                    if self?.currentID == id { self?.uploadBacklogged(diagnostics) }
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

    private func uploadBacklogged(_ snapshot: AudioUploadQueue.Diagnostics) {
        var message = "待上传语音积压达到保护上限，已停止录音；请重新开始。（UPLOAD-BACKLOG）"
        #if DEBUG
        message += "\n待发 \(snapshot.pendingMilliseconds)ms · 在途 \(snapshot.inFlightMilliseconds)ms\n发送等待 \(snapshot.sendWaitingMilliseconds)ms · 最早 \(snapshot.oldestMilliseconds)ms\n已发 \(snapshot.completedBatches)批 · \(displayState)"
        diagnostic("upload_backlog pending_ms=\(snapshot.pendingMilliseconds) in_flight_ms=\(snapshot.inFlightMilliseconds) waiting_ms=\(snapshot.sendWaitingMilliseconds) oldest_ms=\(snapshot.oldestMilliseconds) batches=\(snapshot.completedBatches) display=\(displayState)")
        #endif
        fail(message)
    }

    private func fail(_ message: String) {
        diagnostic("session_failed")
        reset()
        phase = .failed(message)
    }

    private func diagnostic(_ event: String) {
        #if DEBUG
        // Controlled stage names/counts only: no audio, transcripts, tokens or URLs.
        print("SESSION_DIAGNOSTIC \(event)")
        #endif
    }

    private func reset() {
        microphoneReceiving = false
        activity = nil
        currentID = UUID()
        timeout?.cancel()
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

    private struct ServerEvent: Decodable {
        let type: String
        var channel: String?
        var delta: String?
        var eventID: String?
        var message: String?
        var sampleRate: Int?
        var channels: Int?
        var format: String?
    }
}
