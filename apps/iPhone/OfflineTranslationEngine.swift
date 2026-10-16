import Foundation
import WatchConnectivity
import Speech
import AVFoundation
import NaturalLanguage
import Translation

/// The three languages the user actually translates between.
/// iPhone-only: Translation framework has no watchOS counterpart.
enum OfflineLanguage: CaseIterable {
    case chinese, english, spanish

    var speechLocale: Locale {
        switch self {
        case .chinese: return Locale(identifier: "zh-CN")
        case .english: return Locale(identifier: "en-US")
        case .spanish: return Locale(identifier: "es-MX")
        }
    }

    /// Identifiers accepted by TranslationSession / LanguageAvailability.
    var translationLanguage: Locale.Language {
        switch self {
        case .chinese: return Locale.Language(identifier: "zh-Hans")
        case .english: return Locale.Language(identifier: "en-US")
        case .spanish: return Locale.Language(identifier: "es-MX")
        }
    }

    var nlLanguage: NLLanguage {
        switch self {
        case .chinese: return .simplifiedChinese
        case .english: return .english
        case .spanish: return .spanish
        }
    }

    /// BCP-47 code for AVSpeechSynthesisVoice (used on the watch).
    var ttsCode: String {
        switch self {
        case .chinese: return "zh-CN"
        case .english: return "en-US"
        case .spanish: return "es-MX"
        }
    }

    var displayName: String {
        switch self {
        case .chinese: return "中文"
        case .english: return "英语"
        case .spanish: return "西班牙语"
        }
    }
}

extension LanguagePair {
    /// Maps each pair to its two OfflineLanguages.
    var offlineLanguages: (OfflineLanguage, OfflineLanguage) {
        switch self {
        case .chineseEnglish: return (.chinese, .english)
        case .chineseSpanish: return (.chinese, .spanish)
        case .englishSpanish: return (.english, .spanish)
        }
    }

    func offlineOther(_ lang: OfflineLanguage) -> OfflineLanguage {
        let (a, b) = offlineLanguages
        return lang == a ? b : a
    }
}

/// iPhone-side offline translation engine.
///
/// Pipeline (all on-device, no network):
/// watch records utterance -> audio file over Bluetooth -> speech recognition
/// (on-device) -> language ID (NLLanguageRecognizer, constrained to the pair)
/// -> Translation framework (Apple's offline models, shared with the
/// Translate app) -> translated text back to the watch, which shows captions
/// and speaks it aloud.
///
/// Requires iOS 26+ (headless TranslationSession). Requires the offline
/// language packs: download them once in the Translate app — packs the
/// system or any app downloaded are usable here.
@MainActor
final class OfflineTranslationEngine {
    static let shared = OfflineTranslationEngine()
    private init() {}

    enum EngineError: LocalizedError {
        case needsIOS26
        case speechNotAuthorized
        case noRecognizer(OfflineLanguage)
        case recognitionFailed(String)
        case emptySpeech
        case packNotInstalled(OfflineLanguage, OfflineLanguage)

        var errorDescription: String? {
            switch self {
            case .needsIOS26:
                return "离线翻译需要 iOS 26 及以上系统。"
            case .speechNotAuthorized:
                return "请允许语音识别：iPhone 设置 → 腕译 → 语音识别。"
            case .noRecognizer(let lang):
                return "\(lang.displayName)暂不支持端侧语音识别。"
            case .recognitionFailed(let s):
                return "语音识别失败：\(s)（可能需要先下载听写语言包：设置 → 通用 → 键盘 → 听写语言）"
            case .emptySpeech:
                return "没识别到语音，请再说一遍。"
            case .packNotInstalled(let a, let b):
                return "离线语言包未下载：请先在翻译 App 里下载「\(a.displayName)」「\(b.displayName)」的离线包（下过的包本 App 可直接用）。"
            }
        }
    }

    // MARK: - WatchConnectivity entry point

    /// Called from ConfigurationStore's WCSession delegate (iPhone side).
    /// Takes ownership SYNCHRONOUSLY: the system may delete the Inbox file
    /// as soon as the delegate method returns, so we copy it before any
    /// await. Returns the safe copy URL and metadata, or nil on failure.
    nonisolated static func takeOwnership(of file: WCSessionFile) -> (URL, [String: Any]?)? {
        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent("rx-\(UUID().uuidString).wav")
        do {
            try FileManager.default.copyItem(at: file.fileURL, to: dst)
            return (dst, file.metadata)
        } catch {
            return nil
        }
    }

    /// Ack immediately so the watch can tell "iPhone has the file" apart
    /// from "iPhone is still working on it", then process in order.
    /// The URL is our own tmp copy (see takeOwnership).
    func received(_ url: URL, metadata: [String: Any]?) async {
        WCSession.default.transferUserInfo(["received": true])
        enqueue((url, metadata))
    }

    /// The Inbox file vanished before we could copy it.
    func reportReceiveFailure(metadata: [String: Any]?) async {
        let requestID = metadata?["requestID"] as? String ?? UUID().uuidString
        reply(["requestID": requestID,
               "error": "手机没能收下这句音频（传输后文件丢失），请再说一遍"])
    }

    /// Serial queue: utterances are processed in arrival order so the
    /// watch speaks translations back in the order they were spoken.
    private var queue: [(url: URL, metadata: [String: Any]?)] = []
    private var processing = false

    private func enqueue(_ item: (url: URL, metadata: [String: Any]?)) {
        queue.append(item)
        processNext()
    }

    private func processNext() {
        guard !processing, !queue.isEmpty else { return }
        processing = true
        let item = queue.removeFirst()
        Task {
            await self.handle(item)
            self.processing = false
            self.processNext()
        }
    }

    private func handle(_ item: (url: URL, metadata: [String: Any]?)) async {
        let meta = item.metadata ?? [:]
        let requestID = meta["requestID"] as? String ?? UUID().uuidString
        let pair = LanguagePair(rawValue: meta["pair"] as? String ?? "") ?? .chineseEnglish
        defer { try? FileManager.default.removeItem(at: item.url) }
        do {
            guard #available(iOS 26, *) else { throw EngineError.needsIOS26 }
            let (sourceText, sourceLang, viaServer) = try await recognize(url: item.url, pair: pair)
            let targetLang = pair.offlineOther(sourceLang)
            let translated = try await translate(
                sourceText,
                source: sourceLang.translationLanguage,
                target: targetLang.translationLanguage
            )
            reply([
                "requestID": requestID,
                "sourceText": sourceText,
                "translatedText": translated,
                "targetLang": targetLang.ttsCode,
                "viaServer": viaServer,
            ])
        } catch {
            reply([
                "requestID": requestID,
                "error": (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
            ])
        }
    }

    private func reply(_ dict: [String: Any]) {
        WCSession.default.transferUserInfo(dict)
    }

    // MARK: - On-device speech recognition

    private var activeTasks: [SFSpeechRecognitionTask] = []
    /// Continuations waiting on recognition callbacks. The result handler
    /// can go silent (wedged on-device model); the watchdog resumes these
    /// directly so the serial queue can never stall without an error.
    private var pendingContinuations: [UUID: CheckedContinuation<String, Error>] = [:]

    /// Recognizes with both candidate locales in parallel, then picks the
    /// transcript whose identified language matches its recognizer locale.
    /// Returns whether any recognition fell back to Apple's servers.
    private func recognize(url: URL, pair: LanguagePair) async throws -> (String, OfflineLanguage, Bool) {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw EngineError.speechNotAuthorized
        }
        let (langA, langB) = pair.offlineLanguages
        // Watchdog: if neither recognizer answers within 25 s, fail loudly
        // instead of wedging the queue — otherwise the watch shows nothing.
        let watchdog = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 25_000_000_000)
            } catch {
                return // recognition finished in time; watchdog cancelled
            }
            await self?.timeoutRecognition()
        }
        defer { watchdog.cancel() }
        async let textA = recognizeText(url: url, language: langA)
        async let textB = recognizeText(url: url, language: langB)
        let ((a, viaA), (b, viaB)) = try await (textA, textB)
        guard !a.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !b.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EngineError.emptySpeech
        }
        let (text, lang) = pickBest(a: (a, langA), b: (b, langB))
        return (text, lang, viaA || viaB)
    }

    /// Fires pending recognitions with a timeout error and cancels the tasks.
    private func timeoutRecognition() {
        let pending = pendingContinuations
        pendingContinuations.removeAll()
        let error = EngineError.recognitionFailed("识别超时（25秒）。请检查：设置 → 通用 → 键盘 → 听写语言 是否已下载对应语言")
        for (_, continuation) in pending {
            continuation.resume(throwing: error)
        }
        for task in activeTasks { task.cancel() }
        activeTasks.removeAll()
    }

    /// Tries on-device recognition first; if the on-device model isn't
    /// downloaded yet (the 听写语言 download can lag behind the Settings
    /// checkmark), falls back to server recognition so the feature works
    /// now and goes fully offline once the model arrives.
    /// Returns the transcript and whether the server path was used.
    private func recognizeText(url: URL, language: OfflineLanguage) async throws -> (String, Bool) {
        guard let recognizer = SFSpeechRecognizer(locale: language.speechLocale),
              recognizer.isAvailable else {
            throw EngineError.noRecognizer(language)
        }
        var onDeviceError: Error?
        if recognizer.supportsOnDeviceRecognition {
            do {
                let text = try await recognizeText(url: url, recognizer: recognizer, onDevice: true)
                return (text, false)
            } catch {
                onDeviceError = error
            }
        }
        do {
            let text = try await recognizeText(url: url, recognizer: recognizer, onDevice: false)
            return (text, true)
        } catch {
            let serverMsg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if let od = onDeviceError {
                let odMsg = (od as? LocalizedError)?.errorDescription ?? od.localizedDescription
                throw EngineError.recognitionFailed("端侧失败（\(odMsg)）；在线也失败（\(serverMsg)）")
            }
            throw error
        }
    }

    private func recognizeText(url: URL, recognizer: SFSpeechRecognizer, onDevice: Bool) async throws -> String {
        // Read the file ourselves with AVAudioFile: a corrupt file now
        // throws a real, specific error instead of surfacing as
        // AVErrorUnknown (-11800) from inside the Speech framework. Then
        // stream PCM buffers — this avoids any file-handling quirks of
        // SFSpeechURLRecognitionRequest entirely.
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: url)
        } catch {
            let ns = error as NSError
            throw EngineError.recognitionFailed("音频文件无法解析（\(ns.domain) \(ns.code)：\(error.localizedDescription)）")
        }
        let length = audioFile.length
        guard length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.fileFormat,
                                            frameCapacity: AVAudioFrameCount(length)) else {
            throw EngineError.recognitionFailed("音频为空或无法分配缓冲")
        }
        do {
            try audioFile.read(into: buffer)
        } catch {
            throw EngineError.recognitionFailed("音频读取失败：\(error.localizedDescription)")
        }
        guard buffer.frameLength > 0 else {
            throw EngineError.recognitionFailed("音频为空")
        }
        guard signalPresent(in: buffer) else {
            throw EngineError.recognitionFailed("音频里没有有效语音信号（可能是静音片段），请靠近手表正常说话")
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = onDevice
        let id = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            pendingContinuations[id] = continuation
            var task: SFSpeechRecognitionTask?
            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                guard let self else { return }
                // Already resumed (e.g. by the watchdog): ignore late callbacks.
                guard self.pendingContinuations.removeValue(forKey: id) != nil else { return }
                if let error {
                    self.endTask(task)
                    let ns = error as NSError
                    continuation.resume(throwing: EngineError.recognitionFailed("\(error.localizedDescription)（\(ns.domain) \(ns.code)）"))
                    return
                }
                if let result, result.isFinal {
                    self.endTask(task)
                    continuation.resume(returning: result.bestTranscription.formattedString)
                }
            }
            if let task { self.activeTasks.append(task) }
            request.append(buffer)
            request.endAudio()
        }
    }

    /// The VAD already gated on energy watch-side, but a truncated transfer
    /// can still deliver near-silence; catch it here with a clear message
    /// instead of the recognizer's vague "no speech detected".
    private func signalPresent(in buffer: AVAudioPCMBuffer) -> Bool {
        guard let channel = buffer.int16ChannelData else { return true }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return false }
        var sum: Double = 0
        var n = 0
        var i = 0
        let ptr = channel[0]
        while i < count {
            let s = Double(ptr[i])
            sum += s * s
            n += 1
            i += 16 // sparse sampling is plenty for an energy gate
        }
        guard n > 0 else { return false }
        return (sum / Double(n)).squareRoot() > 120
    }

    private func endTask(_ task: SFSpeechRecognitionTask?) {
        guard let task else { return }
        activeTasks.removeAll { $0 === task }
    }

    private func pickBest(
        a: (String, OfflineLanguage),
        b: (String, OfflineLanguage)
    ) -> (String, OfflineLanguage) {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [a.1.nlLanguage, b.1.nlLanguage]
        func score(_ text: String, _ lang: OfflineLanguage) -> Double {
            recognizer.reset()
            recognizer.processString(text)
            return recognizer.languageHypotheses(withMaximum: 2)[lang.nlLanguage] ?? 0
        }
        let scoreA = score(a.0, a.1)
        let scoreB = score(b.0, b.1)
        if scoreA == 0 && scoreB == 0 {
            // Very short utterances may not identify: longer transcript wins.
            return a.0.count >= b.0.count ? a : b
        }
        return scoreA >= scoreB ? a : b
    }

    // MARK: - On-device translation (iOS 26+)

    @available(iOS 26, *)
    private func translate(
        _ text: String,
        source: Locale.Language,
        target: Locale.Language
    ) async throws -> String {
        let availability = LanguageAvailability()
        let status = await availability.status(from: source, to: target)
        guard status == .installed else {
            let a = OfflineLanguage.allCases.first { $0.translationLanguage == source }
            let b = OfflineLanguage.allCases.first { $0.translationLanguage == target }
            throw EngineError.packNotInstalled(a ?? .chinese, b ?? .english)
        }
        let session = TranslationSession(installedSource: source, target: target)
        let response = try await session.translate(text)
        return response.targetText
    }

    // MARK: - Pack status for settings UI

    /// True when the pair's offline packs are on-device (packs are
    /// per-language and shared with the Translate app).
    @available(iOS 26, *)
    func packReady(pair: LanguagePair) async -> Bool {
        let (a, b) = pair.offlineLanguages
        let availability = LanguageAvailability()
        let status = await availability.status(from: a.translationLanguage, to: b.translationLanguage)
        return status == .installed
    }
}
