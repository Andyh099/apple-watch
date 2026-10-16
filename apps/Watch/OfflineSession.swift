import Foundation
import WatchKit
import WatchConnectivity
import AVFoundation

/// Offline (on-device, iPhone-relayed) CONTINUOUS translation session.
///
/// Tap 开始连续翻译 once and just talk: the watch captures continuously with
/// an adaptive energy VAD that segments utterances automatically. Each
/// utterance goes to the iPhone over Bluetooth (no internet); the iPhone
/// recognizes and translates fully on-device and sends text back; the watch
/// shows captions and speaks the translation aloud through its speaker.
///
/// VAD is paused while TTS is speaking (belt-and-braces alongside the
/// voice-processing echo cancellation) so translations never feed back
/// into the microphone.
@MainActor
final class OfflineSession: NSObject, ObservableObject {
    static let shared = OfflineSession()

    enum Phase: Equatable {
        case idle, listening, failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published var sourceText = ""
    @Published var translatedText = ""
    @Published var notice: String?
    @Published private(set) var utteranceCount = 0
    /// Utterances cut by VAD and handed to WCSession. Diagnostic: if this
    /// stays 0 while talking, VAD isn't segmenting; if it grows while
    /// utteranceCount doesn't, the iPhone side is stuck.
    @Published private(set) var sentCount = 0

    var isRunning: Bool { phase == .listening }

    private let audio = DuplexAudio()
    private var frameContinuation: AsyncStream<Data>.Continuation?
    private var frameTask: Task<Void, Never>?
    private var ttsSpeaking = false
    private var runtimeSession: WKExtendedRuntimeSession?
    private let synthesizer = AVSpeechSynthesizer()
    private var sessionID = UUID()

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Session control

    func start() {
        guard !isRunning else { return }
        notice = nil
        sourceText = ""
        translatedText = ""
        utteranceCount = 0
        sentCount = 0
        Task {
            guard await DuplexAudio.requestPermission() else {
                self.phase = .failed("没有麦克风权限，请在系统设置中开启。")
                return
            }
            do {
                try await self.beginCapture()
            } catch {
                self.fail((error as? LocalizedError)?.errorDescription
                    ?? "无法启动麦克风：\(error.localizedDescription)")
            }
        }
    }

    private func beginCapture() async throws {
        let id = UUID()
        sessionID = id
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        frameContinuation = continuation
        beginExtendedRuntime()
        phase = .listening
        notice = "直接说话，自动分句翻译"
        frameTask?.cancel()
        frameTask = Task { await self.consumeFrames(stream) }
        // The audio session must be activated before capture starts —
        // skipping this made every tap fail with "音频会话尚未就绪".
        try await audio.prepareForConnection(sessionID: id)
        try await audio.start(
            sessionID: id,
            onFrame: { data in continuation.yield(data) },
            onFailure: { [weak self] message in
                Task { @MainActor [weak self] in self?.fail(message) }
            }
        )
        notice = "直接说话，自动分句翻译"
    }

    func stop() {
        frameTask?.cancel()
        frameTask = nil
        frameContinuation?.finish()
        frameContinuation = nil
        audio.stop()
        synthesizer.stopSpeaking(at: .immediate)
        ttsSpeaking = false
        endExtendedRuntime()
        phase = .idle
        notice = nil
    }

    private func fail(_ message: String) {
        stop()
        phase = .failed(message)
    }

    // MARK: - VAD segmentation (runs on the MainActor consumer task)

    private func consumeFrames(_ stream: AsyncStream<Data>) async {
        var vad = VadSegmenter()
        for await data in stream {
            guard !Task.isCancelled else { break }
            if ttsSpeaking { continue }  // don't listen to our own speaker
            if let pcm = vad.process(data) {
                sendUtterance(pcm)
            }
        }
    }

    private func sendUtterance(_ pcm: Data) {
        let requestID = UUID().uuidString
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("utt-\(requestID).wav")
        do {
            try wavData(pcm: pcm).write(to: url)
        } catch {
            notice = "写录音文件失败"
            return
        }
        WCSession.default.transferFile(url, metadata: [
            "requestID": requestID,
            "pair": ConfigurationStore.shared.languagePair.rawValue,
        ])
        sentCount += 1
        notice = "已发送 \(sentCount) 句，等待手机识别…"
    }

    // MARK: - iPhone reply (via ConfigurationStore's WCSession delegate)

    func receivedUserInfo(_ userInfo: [String: Any]) {
        guard phase == .listening else { return }
        // Replies are serialized iPhone-side, so the latest is the current one.
        if let error = userInfo["error"] as? String {
            notice = error
            return
        }
        guard let translated = userInfo["translatedText"] as? String,
              !translated.isEmpty else { return }
        sourceText = userInfo["sourceText"] as? String ?? ""
        translatedText = translated
        utteranceCount += 1
        notice = nil
        speak(translated, languageCode: userInfo["targetLang"] as? String)
    }

    // MARK: - Speak the translation on the watch speaker (offline voices)

    private func speak(_ text: String, languageCode: String?) {
        let utterance = AVSpeechUtterance(string: text)
        if let code = languageCode,
           let voice = AVSpeechSynthesisVoice(language: code) {
            utterance.voice = voice
        }
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        ttsSpeaking = true
        synthesizer.speak(utterance)
    }

    // MARK: - Keep-alive

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

    // MARK: - WAV writer (24 kHz, 16-bit, mono)

    private func wavData(pcm: Data) -> Data {
        var header = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { header.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { header.append(contentsOf: $0) } }
        header.append(contentsOf: "RIFF".utf8); u32(UInt32(36 + pcm.count))
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8); u32(16)
        u16(1); u16(1); u32(24_000); u32(24_000 * 2); u16(2); u16(16)
        header.append(contentsOf: "data".utf8); u32(UInt32(pcm.count))
        return header + pcm
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension OfflineSession: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Resume listening only when the whole TTS queue drained.
            if !synthesizer.isSpeaking { self.ttsSpeaking = false }
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in
            self?.ttsSpeaking = false
        }
    }
}

// MARK: - Adaptive energy VAD (24 kHz int16 mono PCM)

/// Segments speech into utterances. Thresholds adapt to the ambient noise
/// floor, so it works from quiet rooms to coffee shops.
struct VadSegmenter {
    private var noiseFloor = 150.0
    private var inSpeech = false
    private var silenceWindows = 0
    private var speechWindows = 0
    private var pcm = Data()
    private var remainder = Data()

    private static let windowBytes = 960       // 20 ms @ 24 kHz int16 mono
    private static let startWindows = 2        // 40 ms to trigger
    private static let endSilenceWindows = 40  // 800 ms silence ends utterance
    private static let minSpeechMs = 350
    private static let maxWindows = 600        // 12 s hard cap

    /// Feeds raw PCM; returns a completed utterance when VAD cuts one.
    mutating func process(_ data: Data) -> Data? {
        var bytes = remainder + data
        remainder = Data()
        var completed: Data?
        while bytes.count >= Self.windowBytes {
            let window = bytes.prefix(Self.windowBytes)
            bytes = bytes.dropFirst(Self.windowBytes)
            if let done = processWindow(window) { completed = done }
        }
        remainder = Data(bytes)
        return completed
    }

    private mutating func processWindow(_ window: Data) -> Data? {
        let rms = rmsOf(window)
        let speaking: Bool
        if inSpeech {
            speaking = rms > max(noiseFloor * 2.0, 220)
        } else {
            speaking = rms > max(noiseFloor * 3.0, 300)
            if !speaking {
                noiseFloor = min(600, max(80, noiseFloor * 0.995 + rms * 0.005))
            }
        }
        if speaking {
            pcm.append(window)
            if !inSpeech {
                speechWindows += 1
                if speechWindows >= Self.startWindows {
                    inSpeech = true
                    silenceWindows = 0
                }
            } else {
                silenceWindows = 0
            }
        } else {
            speechWindows = 0
            if inSpeech {
                pcm.append(window)
                silenceWindows += 1
                if silenceWindows >= Self.endSilenceWindows {
                    return finish()
                }
            }
        }
        if inSpeech, pcm.count / Self.windowBytes >= Self.maxWindows {
            return finish()
        }
        return nil
    }

    private mutating func finish() -> Data? {
        defer {
            inSpeech = false
            silenceWindows = 0
            speechWindows = 0
            pcm = Data()
        }
        let ms = pcm.count / 48  // 24 kHz * 2 bytes = 48 bytes/ms
        guard ms >= Self.minSpeechMs else { return nil }
        return pcm
    }

    private func rmsOf(_ window: Data) -> Double {
        // int16 little-endian mono; decoded byte-wise (no alignment assumptions).
        let n = window.count / 2
        guard n > 0 else { return 0 }
        var sum: Double = 0
        window.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            for i in 0..<n {
                let lo = UInt16(ptr[i * 2])
                let hi = UInt16(ptr[i * 2 + 1])
                let s = Double(Int16(bitPattern: lo | (hi << 8)))
                sum += s * s
            }
        }
        return (sum / Double(n)).squareRoot()
    }
}
