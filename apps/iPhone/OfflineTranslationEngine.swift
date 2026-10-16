import Foundation
import WatchConnectivity
import Speech
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
    nonisolated func receivedFile(_ file: WCSessionFile) {
        Task { await OfflineTranslationEngine.shared.enqueue(file) }
    }

    /// Serial queue: utterances are processed in arrival order so the
    /// watch speaks translations back in the order they were spoken.
    private var queue: [WCSessionFile] = []
    private var processing = false

    private func enqueue(_ file: WCSessionFile) {
        queue.append(file)
        processNext()
    }

    private func processNext() {
        guard !processing, !queue.isEmpty else { return }
        processing = true
        let file = queue.removeFirst()
        Task {
            await self.handle(file)
            self.processing = false
            self.processNext()
        }
    }

    private func handle(_ file: WCSessionFile) async {
        let meta = file.metadata ?? [:]
        let requestID = meta["requestID"] as? String ?? UUID().uuidString
        let pair = LanguagePair(rawValue: meta["pair"] as? String ?? "") ?? .chineseEnglish
        defer { try? FileManager.default.removeItem(at: file.fileURL) }
        do {
            guard #available(iOS 26, *) else { throw EngineError.needsIOS26 }
            let (sourceText, sourceLang) = try await recognize(url: file.fileURL, pair: pair)
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

    /// Recognizes with both candidate locales in parallel, then picks the
    /// transcript whose identified language matches its recognizer locale.
    private func recognize(url: URL, pair: LanguagePair) async throws -> (String, OfflineLanguage) {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw EngineError.speechNotAuthorized
        }
        let (langA, langB) = pair.offlineLanguages
        async let textA = recognizeText(url: url, language: langA)
        async let textB = recognizeText(url: url, language: langB)
        let (a, b) = try await (textA, textB)
        guard !a.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !b.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EngineError.emptySpeech
        }
        return pickBest(a: (a, langA), b: (b, langB))
    }

    private func recognizeText(url: URL, language: OfflineLanguage) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(locale: language.speechLocale) else {
            throw EngineError.noRecognizer(language)
        }
        guard recognizer.isAvailable else { throw EngineError.noRecognizer(language) }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        return try await withCheckedThrowingContinuation { continuation in
            var finished = false
            var task: SFSpeechRecognitionTask?
            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                guard !finished else { return }
                if let error {
                    finished = true
                    self?.endTask(task)
                    continuation.resume(throwing: EngineError.recognitionFailed(error.localizedDescription))
                    return
                }
                if let result, result.isFinal {
                    finished = true
                    self?.endTask(task)
                    continuation.resume(returning: result.bestTranscription.formattedString)
                }
            }
            if let task { self.activeTasks.append(task) }
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
