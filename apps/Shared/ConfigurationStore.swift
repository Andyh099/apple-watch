import Foundation
import Combine
import Security
import WatchConnectivity

/// Which translation engine the watch uses. Synced from the iPhone app.
enum EngineMode: String, CaseIterable {
    /// Watch talks to OpenAI directly (realtime, needs network).
    case online = "online"
    /// Watch records an utterance and the iPhone translates fully on-device
    /// (no network). Requires iOS 26+.
    case offline = "offline"

    var displayName: String {
        switch self {
        case .online: return "在线直连"
        case .offline: return "离线手机中转"
        }
    }
}

/// Development pairing only. The OpenAI API key lives in the Keychain on each
/// device and is synced to the watch over the system's encrypted
/// WatchConnectivity channel. It is never logged, displayed, or put in a URL.
final class ConfigurationStore: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = ConfigurationStore()
    @Published private(set) var configuration: SessionConfiguration?
    @Published private(set) var status = "尚未配置 API Key"
    /// Language pair picked in the iPhone app, synced to the watch.
    /// Defaults to Chinese–English (the original behavior).
    @Published private(set) var languagePair: LanguagePair = {
        if let raw = UserDefaults.standard.string(forKey: "languagePair"),
           let pair = LanguagePair(rawValue: raw) { return pair }
        return .chineseEnglish
    }()
    /// Online (OpenAI realtime) or offline (iPhone on-device). Synced to watch.
    @Published private(set) var engineMode: EngineMode = {
        if let raw = UserDefaults.standard.string(forKey: "engineMode"),
           let mode = EngineMode(rawValue: raw) { return mode }
        return .online
    }()
    private let service = "dev.wristinterpreter.openai-key"
    // Legacy relay-era storage; removed best-effort on first save.
    private let legacyService = "dev.wristinterpreter.device-token"
    private let legacyEndpointKey = "relay.endpoint"

    override private init() {
        super.init()
        if let key = readKey() {
            configuration = SessionConfiguration(apiKey: key)
            status = "已配置 OpenAI 直连"
        }
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    func save(_ value: SessionConfiguration) throws {
        guard value.validatedAPIKey != nil else { throw ConfigurationError.invalid }
        try writeKey(value.apiKey)
        removeLegacy()
        #if os(watchOS)
        if configuration?.apiKey != value.apiKey {
            UserDefaults.standard.set(false, forKey: "cloudAudioConsent")
        }
        #endif
        configuration = value
        status = "已配置 OpenAI 直连"
        #if os(iOS)
        syncToWatch()
        #endif
    }

    func syncToWatch() {
        guard let key = configuration?.validatedAPIKey else {
            status = "尚未配置 API Key"
            return
        }
        guard WCSession.default.activationState == .activated else {
            status = "已保存，等待设备连接"
            return
        }
        do {
            try WCSession.default.updateApplicationContext([
                "apiKey": key,
                "languagePair": languagePair.rawValue,
                "engineMode": engineMode.rawValue,
            ])
            status = "已提交同步；请在手表确认接收"
        } catch { status = "已保存；暂时无法同步到手表" }
    }

    /// Called from the iPhone settings UI. Persists locally and pushes to
    /// the watch over the encrypted WatchConnectivity channel.
    func setLanguagePair(_ pair: LanguagePair) {
        languagePair = pair
        UserDefaults.standard.set(pair.rawValue, forKey: "languagePair")
        #if os(iOS)
        syncToWatch()
        #endif
    }

    /// Called from the iPhone settings UI. Persists locally and pushes to
    /// the watch over the encrypted WatchConnectivity channel.
    func setEngineMode(_ mode: EngineMode) {
        engineMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "engineMode")
        #if os(iOS)
        syncToWatch()
        #endif
    }

    private func writeKey(_ key: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "device"]
        let attributes: [String: Any] = [kSecValueData as String: Data(key.utf8), kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let result = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if result == errSecItemNotFound {
            let added = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
            guard added == errSecSuccess else { throw ConfigurationError.storage }
        } else if result != errSecSuccess { throw ConfigurationError.storage }
    }

    private func readKey() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "device", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func removeLegacy() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: legacyService, kSecAttrAccount as String: "device"]
        SecItemDelete(query as CFDictionary)
        UserDefaults.standard.removeObject(forKey: legacyEndpointKey)
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            #if os(iOS)
            if activationState == .activated { self.syncToWatch() }
            #endif
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        #if os(watchOS)
        if let raw = applicationContext["languagePair"] as? String,
           let pair = LanguagePair(rawValue: raw) {
            DispatchQueue.main.async { self.setLanguagePair(pair) }
        }
        if let raw = applicationContext["engineMode"] as? String,
           let mode = EngineMode(rawValue: raw) {
            DispatchQueue.main.async { self.setEngineMode(mode) }
        }
        guard let key = applicationContext["apiKey"] as? String else { return }
        DispatchQueue.main.async {
            do { try self.save(SessionConfiguration(apiKey: key)) }
            catch { self.status = "收到的 API Key 无效或无法保存" }
        }
        #endif
    }

    /// Offline pipeline: watch sends utterance audio files here (iPhone),
    /// iPhone replies with user-info dictionaries (watch).
    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        #if os(iOS)
        // Delegate callbacks are nonisolated; hop to the main actor.
        Task { @MainActor in
            OfflineTranslationEngine.shared.receivedFile(file)
        }
        #endif
    }

    /// Sender-side confirmation for watch→iPhone utterance file transfers.
    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        #if os(watchOS)
        // Delegate callbacks are nonisolated; hop to the main actor.
        Task { @MainActor in
            if let error {
                OfflineSession.shared.notice = "音频文件发往手机失败：\(error.localizedDescription)"
            } else {
                OfflineSession.shared.fileDelivered()
            }
        }
        #endif
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        #if os(watchOS)
        // Delegate callbacks are nonisolated; hop to the main actor.
        Task { @MainActor in
            OfflineSession.shared.receivedUserInfo(userInfo)
        }
        #endif
    }

    #if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    #endif

    enum ConfigurationError: LocalizedError {
        case invalid, storage
        var errorDescription: String? {
            switch self {
            case .invalid: return "请输入有效的 OpenAI API Key。"
            case .storage: return "无法将 API Key 保存到钥匙串。"
            }
        }
    }
}
