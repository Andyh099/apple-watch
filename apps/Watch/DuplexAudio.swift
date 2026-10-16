import AVFAudio
import Foundation

/// Device-only audio plumbing. Capture is never muted merely because playback is
/// active. If system voice processing cannot be enabled, fail visibly rather than
/// silently switching to turn-by-turn recording.
final class DuplexAudio: @unchecked Sendable {
    private let queue = DispatchQueue(label: "interpreter.audio", qos: .userInitiated)
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var queuedSamples = 0
    private var generation = UUID()
    private var inputInstalled = false
    private var preparedSessionID: UUID?
    private var activationPending = false
    private var lastCaptureAt: UInt64 = 0
    private var configurationObserver: NSObjectProtocol?
    private var captureGeneration = UUID()
    private var receivedCapture = false
    private var startupReconfigurations = 0
    private var reconfigurationPending = false
    private var onFailure: (@Sendable (String) -> Void)?

    static func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
    }

    /// watchOS requires an active audio session before opening a WebSocket.
    /// This prepares the route only: no engine, input tap, or microphone samples.
    func prepareForConnection(sessionID: UUID) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                // Native activation cannot be cancelled. Do not overlap activations,
                // or a late completion could deactivate a newer session's route.
                guard !self.activationPending else {
                    continuation.resume(throwing: AudioError.activationInProgress)
                    return
                }
                do {
                    self.stopOnQueue()
                    let session = AVAudioSession.sharedInstance()
                    try session.setCategory(.playAndRecord, mode: .voiceChat, options: [])
                    let generation = self.generation
                    self.activationPending = true
                    // On watchOS, synchronous setActive(true) is not sufficient
                    // to authorize low-level audio networking. Wait for activation.
                    session.activate(options: []) { activated, error in
                        self.queue.async {
                            self.activationPending = false
                            guard self.generation == generation else {
                                self.stopOnQueue()
                                continuation.resume(throwing: CancellationError())
                                return
                            }
                            guard activated, error == nil else {
                                self.stopOnQueue()
                                continuation.resume(throwing: error ?? AudioError.activationRejected)
                                return
                            }
                            self.preparedSessionID = sessionID
                            continuation.resume()
                        }
                    }
                } catch {
                    self.stopOnQueue()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func start(sessionID: UUID, onFrame: @escaping @Sendable (Data) -> Void, onFailure: @escaping @Sendable (String) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                // A cancelled connection must not start capture or stop a newer session.
                guard self.preparedSessionID == sessionID, self.engine == nil else {
                    continuation.resume(throwing: AudioError.sessionNotPrepared)
                    return
                }
                do {
                    // Keep the already-active route throughout the WebSocket lifetime.
                    self.onFailure = onFailure
                    let engine = AVAudioEngine()
                    self.engine = engine
                    let generation = self.generation
                    // The notification can arrive on an internal audio thread.
                    // Never stop, rewire or release the engine in that callback.
                    self.configurationObserver = NotificationCenter.default.addObserver(
                        forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
                    ) { [weak self] _ in
                        self?.queue.async { [weak self] in
                            self?.configurationChanged(generation: generation, onFrame: onFrame)
                        }
                    }
                    try engine.inputNode.setVoiceProcessingEnabled(true)
                    guard engine.inputNode.isVoiceProcessingEnabled else { throw AudioError.voiceProcessingUnavailable }
                    let player = AVAudioPlayerNode()
                    self.player = player
                    engine.attach(player)
                    try self.configureAndStart(engine: engine, player: player, onFrame: onFrame)
                    self.checkCapture(generation: generation)
                    continuation.resume()
                } catch {
                    self.stopOnQueue()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Re-read hardware formats after voice processing or route configuration.
    /// The same active session is retained; this never reactivates a stopped one.
    private func configureAndStart(engine: AVAudioEngine, player: AVAudioPlayerNode, onFrame: @escaping @Sendable (Data) -> Void) throws {
        guard engine.inputNode.isVoiceProcessingEnabled else { throw AudioError.voiceProcessingUnavailable }
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        let outputFormat = engine.outputNode.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              outputFormat.sampleRate > 0, outputFormat.channelCount > 0,
              let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)
        else { throw AudioError.formatUnavailable }

        let converter = try StreamingPCMConverter(inputFormat: inputFormat)
        #if DEBUG
        diagnostic("capture_format_hz=\(Int(inputFormat.sampleRate)) channels=\(inputFormat.channelCount)")
        #endif
        engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: outputFormat)
        let generation = self.generation
        let captureGeneration = UUID()
        self.captureGeneration = captureGeneration
        var frames = AudioFrameBuffer()
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            let bytes: Data
            do { bytes = try converter.convert(buffer) }
            catch {
                self?.captureFailed("麦克风音频转换失败。", generation: generation, captureGeneration: captureGeneration)
                return
            }
            guard !bytes.isEmpty else { return }
            let capturedAt = DispatchTime.now().uptimeNanoseconds
            let readyFrames = frames.append(bytes)
            self?.queue.async { [weak self] in
                guard let self, self.generation == generation,
                      self.captureGeneration == captureGeneration, self.inputInstalled else { return }
                self.lastCaptureAt = capturedAt
                self.receivedCapture = true
                for frame in readyFrames { onFrame(frame) }
            }
        }
        inputInstalled = true
        engine.prepare()
        try engine.start()
        player.play()
        lastCaptureAt = DispatchTime.now().uptimeNanoseconds
        diagnostic("engine_started")
    }

    private func captureFailed(_ message: String, generation: UUID, captureGeneration: UUID) {
        queue.async { [weak self] in
            guard let self, self.generation == generation,
                  self.captureGeneration == captureGeneration, self.inputInstalled else { return }
            self.onFailure?(message)
        }
    }

    private func configurationChanged(generation: UUID, onFrame: @escaping @Sendable (Data) -> Void) {
        guard self.generation == generation, inputInstalled, let engine, !engine.isRunning else { return }
        diagnostic("configuration_changed_engine_stopped")
        guard !reconfigurationPending else { return }
        guard !receivedCapture, queuedSamples == 0, startupReconfigurations < 2 else {
            onFailure?("音频设备配置发生变化，录音已停止（AUDIO-ROUTE）。请重新开始。")
            return
        }
        reconfigurationPending = true
        startupReconfigurations += 1
        // Let the hardware finish switching before reading its formats again.
        queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.generation == generation, self.inputInstalled,
                  let engine = self.engine, let player = self.player else { return }
            self.reconfigurationPending = false
            guard !engine.isRunning else { return }
            // Once PCM has been captured, do not discard or replay audio to recover.
            guard !self.receivedCapture, self.queuedSamples == 0 else {
                self.onFailure?("音频设备配置发生变化，录音已停止（AUDIO-ROUTE）。请重新开始。")
                return
            }
            do {
                self.removeInputTap()
                player.stop()
                engine.stop()
                engine.disconnectNodeOutput(player)
                engine.disconnectNodeOutput(engine.mainMixerNode)
                try self.configureAndStart(engine: engine, player: player, onFrame: onFrame)
                self.diagnostic("startup_reconfigured")
            } catch {
                self.onFailure?("无法重新配置录音设备（AUDIO-ROUTE，错误码 \((error as NSError).code)）。")
            }
        }
    }

    /// Silence still produces PCM. Only a bounded, configuration-notified startup
    /// repair may defer failure; interruptions and user stops never auto-restart.
    private func checkCapture(generation: UUID) {
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.generation == generation, self.inputInstalled else { return }
            if self.reconfigurationPending {
                self.checkCapture(generation: generation)
                return
            }
            guard self.engine?.isRunning == true else {
                self.diagnostic("engine_stopped_without_pending_reconfiguration")
                self.onFailure?("录音引擎启动后停止（AUDIO-ENGINE）。请重新开始。")
                return
            }
            let elapsed = DispatchTime.now().uptimeNanoseconds - self.lastCaptureAt
            guard elapsed < 5_000_000_000 else {
                self.onFailure?("连续五秒未收到麦克风音频，已停止会话（AUDIO-NO-PCM）。请重试。")
                return
            }
            self.checkCapture(generation: generation)
        }
    }

    private func diagnostic(_ event: String) {
        #if DEBUG
        print("AUDIO_DIAGNOSTIC \(event)")
        #endif
    }

    func play(_ bytes: Data) {
        queue.async { [self] in
            guard let player = self.player, self.engine?.isRunning == true else { return }
            let sampleCount = bytes.count / 2
            guard sampleCount > 0, bytes.count % 2 == 0 else { self.onFailure?("收到无效的语音片段。"); return }
            guard self.queuedSamples + sampleCount <= 24_000 * 3 else {
                self.onFailure?("播放延迟超过三秒，已停止会话，请重试。")
                return
            }
            guard let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleCount)),
                  let output = buffer.floatChannelData?[0] else { return }
            buffer.frameLength = AVAudioFrameCount(sampleCount)
            bytes.withUnsafeBytes { raw in
                for index in 0..<sampleCount {
                    let value = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))
                    output[index] = Float(value) / 32768
                }
            }
            self.queuedSamples += sampleCount
            let generation = self.generation
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                guard let self else { return }
                self.queue.async {
                    if generation == self.generation { self.queuedSamples -= sampleCount }
                }
            }
        }
    }

    /// End microphone capture immediately but allow translated output to drain.
    func stopCapture() {
        queue.async { self.removeInputTap() }
    }

    func drainAndStop() async {
        await withCheckedContinuation { continuation in
            queue.async { self.drain(until: Date().addingTimeInterval(4), generation: self.generation, continuation: continuation) }
        }
    }

    private func drain(until deadline: Date, generation: UUID, continuation: CheckedContinuation<Void, Never>) {
        guard generation == self.generation else { continuation.resume(); return }
        if queuedSamples <= 0 || Date() >= deadline {
            stopOnQueue()
            continuation.resume()
        } else {
            queue.asyncAfter(deadline: .now() + 0.05) { self.drain(until: deadline, generation: generation, continuation: continuation) }
        }
    }

    func stop() { queue.async { self.stopOnQueue() } }
    private func removeInputTap() {
        captureGeneration = UUID()
        if inputInstalled { engine?.inputNode.removeTap(onBus: 0); inputInstalled = false }
    }
    private func stopOnQueue() {
        generation = UUID()
        preparedSessionID = nil
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        reconfigurationPending = false
        startupReconfigurations = 0
        receivedCapture = false
        removeInputTap()
        player?.stop()
        engine?.stop()
        engine = nil
        player = nil
        queuedSamples = 0
        lastCaptureAt = 0
        onFailure = nil
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    enum AudioError: LocalizedError {
        case voiceProcessingUnavailable, formatUnavailable, sessionNotPrepared, activationInProgress, activationRejected
        var errorDescription: String? {
            switch self {
            case .voiceProcessingUnavailable: return "此设备或音频路线无法启用语音处理；不会自动降级为轮流录音。"
            case .formatUnavailable: return "当前麦克风或扬声器格式不可用。"
            case .sessionNotPrepared: return "音频会话尚未就绪或已取消，请重新开始。"
            case .activationInProgress: return "上一次音频激活尚未结束，请稍后重试。"
            case .activationRejected: return "系统未能激活音频路线，请结束其他音频后重试。"
            }
        }
    }
}
