import Foundation

public struct SessionConfiguration: Codable, Equatable, Sendable {
    public var endpoint: String
    public var token: String

    public init(endpoint: String, token: String) {
        self.endpoint = endpoint
        self.token = token
    }

    /// Remote audio and credentials are never sent over plaintext websocket URLs.
    public var validatedURL: URL? {
        guard let parts = URLComponents(string: endpoint),
              parts.scheme?.lowercased() == "wss",
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.path == "/interpret",
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !token.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return parts.url
    }
}
