import Foundation

public struct SessionConfiguration: Codable, Equatable, Sendable {
    /// OpenAI API key. Stored in the Keychain on iPhone and watch; never logged,
    /// displayed, or embedded in a URL.
    public var apiKey: String

    public init(apiKey: String) {
        self.apiKey = apiKey
    }

    /// The watch talks to OpenAI's Live API directly over the watch's own
    /// Wi-Fi or cellular connection. No relay in the middle.
    public static let upstreamURL = URL(string: "wss://api.openai.com/v1/live/sessions")!

    /// Basic sanity only: trimmed, long enough, no whitespace or control
    /// characters (they would corrupt the Authorization header). Validity is
    /// proven by the handshake, which reports 401 for a bad key.
    public var validatedAPIKey: String? {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.count >= 20,
              !key.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0)
              })
        else { return nil }
        return key
    }
}
