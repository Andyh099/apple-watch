import Foundation
import Combine
import Security
import WatchConnectivity

/// Development pairing only. OpenAI's project key must NEVER be stored here.
final class ConfigurationStore: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = ConfigurationStore()
    @Published private(set) var configuration: SessionConfiguration?
    @Published private(set) var status = "尚未配置翻译服务"
    private let service = "dev.wristinterpreter.device-token"
    private let endpointKey = "relay.endpoint"

    override private init() {
        super.init()
        if let endpoint = UserDefaults.standard.string(forKey: endpointKey), let token = readToken() {
            configuration = SessionConfiguration(endpoint: endpoint, token: token)
            status = "已有服务配置"
        }
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    func save(_ value: SessionConfiguration) throws {
        guard value.validatedURL != nil else { throw ConfigurationError.invalid }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "device"]
        let attributes: [String: Any] = [kSecValueData as String: Data(value.token.utf8), kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let result = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if result == errSecItemNotFound {
            let added = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
            guard added == errSecSuccess else { throw ConfigurationError.storage }
        } else if result != errSecSuccess { throw ConfigurationError.storage }
        #if os(watchOS)
        if configuration?.endpoint != value.endpoint {
            UserDefaults.standard.set(false, forKey: "cloudAudioConsent")
        }
        #endif
        UserDefaults.standard.set(value.endpoint, forKey: endpointKey)
        configuration = value
        status = "配置已保存"
        #if os(iOS)
        syncToWatch()
        #endif
    }

    func syncToWatch() {
        guard let value = configuration else {
            status = "尚未配置翻译服务"
            return
        }
        guard WCSession.default.activationState == .activated else {
            status = "配置已保存，等待设备连接"
            return
        }
        do {
            try WCSession.default.updateApplicationContext(["endpoint": value.endpoint, "deviceToken": value.token])
            status = "配置已提交同步；请在手表确认接收"
        } catch { status = "配置已保存；暂时无法同步到手表" }
    }

    private func readToken() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "device", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
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
        guard let endpoint = applicationContext["endpoint"] as? String, let token = applicationContext["deviceToken"] as? String else { return }
        DispatchQueue.main.async {
            do { try self.save(SessionConfiguration(endpoint: endpoint, token: token)) }
            catch { self.status = "收到的配置无效或无法保存" }
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
            case .invalid: return "请输入 wss://域名/interpret 和设备令牌。不要填写 OpenAI API Key。"
            case .storage: return "无法将设备令牌保存到钥匙串。"
            }
        }
    }
}
