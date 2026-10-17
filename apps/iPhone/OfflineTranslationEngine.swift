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
        case translateTimedOut
        case recognitionTimedOut

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
            case .translateTimedOut:
                return "翻译超时（45秒），已跳过这一句。请重试。"
            case .recognitionTimedOut:
                return "识别超时（25秒）：语音识别没有响应，已跳过这一句。请检查：设置 → 通用 → 键盘 → 听写语言 是否已下载对应语言。"
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
        // Drop files that queued while the app was closed (previous tests,
        // old builds). Without this they error out and pollute the current
        // test with stale "no speech detected" failures.
        if let sentAt = metadata?["sentAt"] as? Double,
           Date().timeIntervalSince1970 - sentAt > 300 {
            try? FileManager.default.removeItem(at: url)
            return
        }
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
        // Carried into the error reply so the watch can show one screenshot
        // worth of audio diagnostics.
        var statsLine = ""
        defer { try? FileManager.default.removeItem(at: item.url) }
        do {
            guard #available(iOS 26, *) else { throw EngineError.needsIOS26 }
            // Keep a copy for human diagnosis: if the recognizer keeps
            // saying "no speech", playing this file answers in seconds
            // whether the watch actually captured speech. Visible in
            // Finder via File Sharing (utterances/), newest 20 kept.
            saveDebugCopy(url: item.url, requestID: requestID)
            let (buffer, stats) = try loadAudioBuffer(url: item.url)
            statsLine = stats
            let (sourceText, sourceLang, viaServer) = try await recognize(buffer: buffer, pair: pair)
            let targetLang = pair.offlineOther(sourceLang)
            // Stage notice: if the pipeline stalls from here on, the watch
            // shows WHERE it is stuck instead of a generic "识别中…".
            reply(["requestID": requestID, "stage": "translating"])
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
                "audioStats": statsLine,
            ])
        } catch {
            reply([
                "requestID": requestID,
                "error": (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                "audioStats": statsLine,
            ])
        }
    }

    /// Debug archive of received utterances (see handle()).
    private func saveDebugCopy(url: URL, requestID: String) {
        do {
            let dir = try FileManager.default.url(for: .documentDirectory,
                                                  in: .userDomainMask,
                                                  appropriateFor: nil,
                                                  create: true)
                .appendingPathComponent("utterances", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dst = dir.appendingPathComponent("utt-\(requestID).wav")
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.copyItem(at: url, to: dst)
            let files = (try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.creationDateKey],
                options: [.skipsHiddenFiles])) ?? []
            let oldestFirst = files.sorted {
                let da = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let db = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return da < db
            }
            for old in oldestFirst.dropLast(20) { try? FileManager.default.removeItem(at: old) }
        } catch {
            // Diagnostics must never break the pipeline.
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

    /// Recognizes with both candidate locales, each attempted independently:
    /// a failure in one recognizer must never discard the other's
    /// transcript (the old `try await (textA, textB)` did exactly that).
    /// Returns whether any recognition fell back to Apple's servers.
    private func recognize(buffer: AVAudioPCMBuffer, pair: LanguagePair) async throws -> (String, OfflineLanguage, Bool) {
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
        func attempt(_ language: OfflineLanguage) async -> Result<(String, Bool), Error> {
            do {
                return .success(try await recognizeText(buffer: buffer, language: language))
            } catch {
                return .failure(error)
            }
        }
        async let resA = attempt(langA)
        async let resB = attempt(langB)
        let (rA, rB) = await (resA, resB)
        let okA = try? rA.get()
        let okB = try? rB.get()
        switch (okA, okB) {
        case let (a?, b?):
            guard !a.0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || !b.0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw EngineError.emptySpeech
            }
            let (text, lang) = pickBest(a: (a.0, langA), b: (b.0, langB))
            return (text, lang, a.1 || b.1)
        case let (a?, nil):
            guard !a.0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw EngineError.emptySpeech
            }
            return (a.0, langA, a.1)
        case let (nil, b?):
            guard !b.0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw EngineError.emptySpeech
            }
            return (b.0, langB, b.1)
        case (nil, nil):
            if case .failure(let e) = rA { throw e }
            if case .failure(let e) = rB { throw e }
            throw EngineError.emptySpeech
        }
    }

    /// Fires pending recognitions with a timeout error and cancels the tasks.
    /// The timeout is a DISTINCT error (recognitionTimedOut, not a generic
    /// recognitionFailed) so callers can tell "the recognizer went silent"
    /// apart from "it answered with an error" — see recognizeText.
    private func timeoutRecognition() {
        let pending = pendingContinuations
        pendingContinuations.removeAll()
        for (_, continuation) in pending {
            continuation.resume(throwing: EngineError.recognitionTimedOut)
        }
        for task in activeTasks { task.cancel() }
        activeTasks.removeAll()
    }

    /// Tries on-device recognition first; if the on-device model isn't
    /// downloaded yet (the 听写语言 download can lag behind the Settings
    /// checkmark), falls back to server recognition so the feature works
    /// now and goes fully offline once the model arrives.
    /// Returns the transcript and whether the server path was used.
    private func recognizeText(buffer: AVAudioPCMBuffer, language: OfflineLanguage) async throws -> (String, Bool) {
        guard let recognizer = SFSpeechRecognizer(locale: language.speechLocale),
              recognizer.isAvailable else {
            throw EngineError.noRecognizer(language)
        }
        var onDeviceError: Error?
        if recognizer.supportsOnDeviceRecognition {
            do {
                let text = try await recognizeText(buffer: buffer, recognizer: recognizer, onDevice: true)
                return (text, false)
            } catch {
                // The watchdog fired: the recognizer went SILENT (not just
                // "failed"). Falling through to the server path would retry
                // with NO watchdog — if that hangs too, the serial queue
                // wedges forever with no error. Fail fast instead.
                if case EngineError.recognitionTimedOut = error { throw error }
                onDeviceError = error
            }
        }
        do {
            let text = try await recognizeText(buffer: buffer, recognizer: recognizer, onDevice: false)
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

    /// Reads the WAV ourselves with AVAudioFile: a corrupt file now throws
    /// a real, specific error instead of surfacing as AVErrorUnknown
    /// (-11800) from inside the Speech framework. Gates on the loudest
    /// 500 ms window's energy — the watch VAD guarantees every real
    /// utterance holds >= 350 ms of above-threshold speech, so the peak
    /// window is the honest measure; a truncated transfer is quiet in
    /// every window. Returns a one-line stat summary for diagnostics.
    private func loadAudioBuffer(url: URL) throws -> (AVAudioPCMBuffer, String) {
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
        guard let stats = audioStats(buffer) else {
            throw EngineError.recognitionFailed("音频格式不受支持（无法读取采样）")
        }
        let durS = Double(buffer.frameLength) / 24_000.0
        let statsLine = String(format: "%.1fs 能量%.0f/阈值150 峰值%.0f 过零%.2f",
                               durS, stats.peakWindowRms, stats.peak, stats.zcr)
        print("OfflineTranslationEngine: " + statsLine + " file=" + url.lastPathComponent)
        guard stats.peakWindowRms > 150 else {
            throw EngineError.recognitionFailed("音频里没有有效语音信号（\(statsLine)），请靠近手表正常说话")
        }
        return (buffer, statsLine)
    }

    /// Peak-window energy analysis of the int16 mono buffer. Sparse sampling
    /// keeps it cheap; the peak 500 ms window (250 ms hop) is what matters.
    private func audioStats(_ buffer: AVAudioPCMBuffer) -> (peakWindowRms: Double, peak: Double, zcr: Double)? {
        guard let channel = buffer.int16ChannelData else { return nil }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return nil }
        let ptr = channel[0]
        let winLen = 12_000, hop = 6_000  // 500 ms window, 250 ms hop @ 24 kHz
        var peakWindowRms: Double = 0
        var i = 0
        while i < count {
            let end = min(i + winLen, count)
            var sum: Double = 0
            var n = 0
            var j = i
            while j < end {
                let s = Double(ptr[j])
                sum += s * s
                n += 1
                j += 4
            }
            if n > 0 {
                peakWindowRms = max(peakWindowRms, (sum / Double(n)).squareRoot())
            }
            i += hop
        }
        var peak: Double = 0
        var crossings = 0
        var prevSign = 0
        var k = 0
        while k < count {
            let s = Double(ptr[k])
            let a = abs(s)
            if a > peak { peak = a }
            let sign = s > 0 ? 1 : (s < 0 ? -1 : 0)
            if sign != 0 {
                if prevSign != 0, sign != prevSign { crossings += 1 }
                prevSign = sign
            }
            k += 8
        }
        let zcr = Double(crossings) / Double(max(count / 8, 1))
        return (peakWindowRms, peak, zcr)
    }

    /// Streams the PCM buffer into the recognizer. The buffer was already
    /// validated by loadAudioBuffer, so any failure here is the
    /// recognizer's own verdict on the audio.
    private func recognizeText(buffer: AVAudioPCMBuffer, recognizer: SFSpeechRecognizer, onDevice: Bool) async throws -> String {
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
        // Translation previously had NO watchdog: a hung session.translate()
        // wedged the serial queue forever — no error, no timeout, the watch
        // stuck on "识别中…" while later utterances piled up behind it.
        // Race it against 45 s; first finisher wins.
        return try await withCheckedThrowingContinuation { continuation in
            let state = TranslateOnce(continuation)
            Task {
                do {
                    let session = TranslationSession(installedSource: source, target: target)
                    let response = try await session.translate(text)
                    state.complete(.success(response.targetText))
                } catch {
                    state.complete(.failure(error))
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: 45_000_000_000)
                state.complete(.failure(EngineError.translateTimedOut))
            }
        }
    }

    /// One-shot completion box for the translate timeout race:
    /// withCheckedThrowingContinuation traps on a second resume, so the
    /// loser of the race must be ignored, not resumed.
    private final class TranslateOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private let continuation: CheckedContinuation<String, Error>
        init(_ continuation: CheckedContinuation<String, Error>) {
            self.continuation = continuation
        }
        func complete(_ result: Result<String, Error>) {
            lock.lock()
            defer { lock.unlock() }
            guard !done else { return }
            done = true
            switch result {
            case .success(let value):
                continuation.resume(returning: value)
            case .failure(let error):
                continuation.resume(throwing: error)
            }
        }
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
