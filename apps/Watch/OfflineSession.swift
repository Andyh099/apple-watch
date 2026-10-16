import Foundation
import WatchKit
import WatchConnectivity
import AVFoundation

/// Offline (on-device, iPhone-relayed) translation session.
///
/// Utterance-based v1: tap 开始 -> speak -> tap 结束 -> the audio file goes
/// to the iPhone over Bluetooth (no internet); the iPhone recognizes and
/// translates fully on-device and sends text back; the watch shows captions
/// and speaks the translation aloud through its speaker.
///
/// The extended runtime session is held for the whole round trip so the
/// screen never sleeps mid-translation (see the black-screen fix in
/// InterpreterSession.reconnectOrFail).
@MainActor
final class OfflineSession: NSObject, ObservableObject {
    static let shared = OfflineSession()

    enum Phase: Equatable {
        case idle, recording, waiting, failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published var sourceText = ""
    @Published var translatedText = ""
    @Published var notice: String?

    var isRunning: Bool {
        switch phase {
        case .idle, .failed: return false
        case .recording, .waiting: return true
        }
    }

    private var recorder: AVAudioRecorder?
    private var recordURL: URL?
    private var pendingRequestID: String?
    private var runtimeSession: WKExtendedRuntimeSession?
    private var timeout: Task<Void, Never>?
    private let synthesizer = AVSpeechSynthesizer()

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Recording

    func start() {
        guard !isRunning else { return }
        notice = nil
        sourceText = ""
        translatedText = ""
        phase = .idle
        Task {
            guard await DuplexAudio.requestPermission() else {
                self.phase = .failed("没有麦克风权限，请在系统设置中开启。")
                return
            }
            self.beginRecording()
        }
    }

    private func beginRecording() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("utt-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
        ]
        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord)
            recorder = try AVAudioRecorder(url: url, settings: settings)
        } catch {
            phase = .failed("无法开始录音：\(error.localizedDescription)")
            return
        }
        recordURL = url
        recorder?.record()
        beginExtendedRuntime()
        phase = .recording
    }

    /// Stop recording and send the utterance to the iPhone.
    func stop() {
        guard case .recording = phase else { return }
        recorder?.stop()
        recorder = nil
        guard let url = recordURL else {
            phase = .failed("录音文件丢失，请重试。")
            endExtendedRuntime()
            return
        }
        recordURL = nil
        let requestID = UUID().uuidString
        pendingRequestID = requestID
        phase = .waiting
        notice = "正在手机端离线翻译…"
        WCSession.default.transferFile(url, metadata: [
            "requestID": requestID,
            "pair": ConfigurationStore.shared.languagePair.rawValue,
        ])
        timeout?.cancel()
        timeout = Task {
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled, self.pendingRequestID == requestID else { return }
            self.pendingRequestID = nil
            self.phase = .failed("手机端无响应（60 秒）：请确认手机在附近、蓝牙开启。")
            self.endExtendedRuntime()
        }
    }

    func cancel() {
        timeout?.cancel()
        timeout = nil
        recorder?.stop()
        recorder = nil
        recordURL = nil
        pendingRequestID = nil
        synthesizer.stopSpeaking(at: .immediate)
        endExtendedRuntime()
        phase = .idle
        notice = nil
    }

    // MARK: - iPhone reply (via ConfigurationStore's WCSession delegate)

    func receivedUserInfo(_ userInfo: [String: Any]) {
        guard let requestID = userInfo["requestID"] as? String,
              requestID == pendingRequestID else { return }
        pendingRequestID = nil
        timeout?.cancel()
        timeout = nil
        if let error = userInfo["error"] as? String {
            phase = .failed(error)
            endExtendedRuntime()
            return
        }
        sourceText = userInfo["sourceText"] as? String ?? ""
        translatedText = userInfo["translatedText"] as? String ?? ""
        notice = nil
        phase = .idle
        // Keep the runtime session until TTS finishes (delegate ends it).
        speak(translatedText, languageCode: userInfo["targetLang"] as? String)
    }

    // MARK: - Speak the translation on the watch speaker (offline voices)

    private func speak(_ text: String, languageCode: String?) {
        guard !text.isEmpty else {
            endExtendedRuntime()
            return
        }
        let utterance = AVSpeechUtterance(string: text)
        if let code = languageCode,
           let voice = AVSpeechSynthesisVoice(language: code) {
            utterance.voice = voice
        }
        try? AVAudioSession.sharedInstance().setCategory(.playback)
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
}

// MARK: - AVSpeechSynthesizerDelegate

extension OfflineSession: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            // TTS done: the round trip is fully complete.
            self.endExtendedRuntime()
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            self.endExtendedRuntime()
        }
    }
}
