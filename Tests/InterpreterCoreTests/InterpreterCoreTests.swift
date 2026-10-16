import Foundation
import XCTest
@testable import InterpreterCore

final class InterpreterCoreTests: XCTestCase {
    func testKeepsSilenceAndPacesFrames() {
        var frames = AudioFrameBuffer()
        XCTAssertTrue(frames.append(Data(repeating: 0, count: 4_799)).isEmpty)
        XCTAssertEqual(frames.append(Data([0])).first, Data(repeating: 0, count: 4_800))
        XCTAssertTrue(frames.flush().isEmpty)
    }

    func testArbitraryPacketBoundariesPreserveSamples() {
        var frames = AudioFrameBuffer()
        let original = Data((0..<10_007).map { UInt8($0 % 251) })
        var output = Data()
        for offset in stride(from: 0, to: original.count, by: 97) {
            for frame in frames.append(original.subdata(in: offset..<min(offset + 97, original.count))) {
                output.append(frame)
            }
        }
        output.append(frames.flush())
        XCTAssertEqual(output, original.prefix(10_006))
        XCTAssertTrue(frames.append(Data([42])).isEmpty)
        XCTAssertEqual(frames.flush(), Data([original.last!, 42]))
    }

    func testCaptionsPreserveSpacingAndIntentionalRepetition() {
        var captions = TranscriptBuffer()
        captions.append("No", to: .source, eventID: "a")
        captions.append(", no", to: .source, eventID: "b")
        captions.append(", no", to: .source, eventID: "b")
        captions.append("不是", to: .translation, eventID: "c")
        captions.append("，不是", to: .translation, eventID: "d")
        XCTAssertEqual(captions.source, "No, no")
        XCTAssertEqual(captions.translation, "不是，不是")
    }

    func testBoundedCaptionsDoNotLoseChannelIndependence() {
        var captions = TranscriptBuffer(characterLimit: 4)
        captions.append("你好世界呀", to: .translation, eventID: nil)
        captions.append("hello", to: .source, eventID: nil)
        XCTAssertEqual(captions.translation, "好世界呀")
        XCTAssertEqual(captions.source, "ello")
    }

    func testAPIKeyValidation() {
        for key in ["", "short", "has space inside this key abcdef", "bad\nkey abcdefghijklmnop", "bad\tkey abcdefghijklmnop", "bad\u{7f}key abcdefghijklmnop"] {
            XCTAssertNil(SessionConfiguration(apiKey: key).validatedAPIKey, "key: \(key)")
        }
        XCTAssertNotNil(SessionConfiguration(apiKey: "sk-test-0123456789abcdef0123456789").validatedAPIKey)
        // Leading/trailing whitespace is trimmed, not rejected.
        XCTAssertEqual(SessionConfiguration(apiKey: "  sk-test-0123456789abcdef0123456789  ").validatedAPIKey,
                       "sk-test-0123456789abcdef0123456789")
    }
    func testConnectionFailuresDistinguishAuthorizationAndNetwork() {
        let error = URLError(.badServerResponse)
        for status in [401, 403] {
            let message = ConnectionFailure.message(for: error, httpStatus: status)
            XCTAssertTrue(message.contains("API Key"))
            XCTAssertTrue(message.contains("HTTP \(status)"))
        }
        XCTAssertTrue(ConnectionFailure.message(for: error, httpStatus: 404).contains("404"))
        XCTAssertTrue(ConnectionFailure.message(for: error, httpStatus: 429).contains("429"))
        XCTAssertTrue(ConnectionFailure.message(for: error, httpStatus: 502).contains("502"))
        XCTAssertTrue(ConnectionFailure.message(for: URLError(.notConnectedToInternet)).contains("-1009"))
        XCTAssertTrue(ConnectionFailure.message(for: URLError(.cannotFindHost)).contains("解析"))
        XCTAssertTrue(ConnectionFailure.message(for: URLError(.serverCertificateUntrusted)).contains("不会跳过"))
    }

    func testConnectionDiagnosticsNeverEchoRawSecrets() {
        let secret = "private-device-token"
        let error = NSError(domain: NSURLErrorDomain, code: -1011, userInfo: [
            NSLocalizedDescriptionKey: "Authorization: Bearer " + secret,
            NSURLErrorFailingURLStringErrorKey: "wss://private.example/" + secret
        ])
        let message = ConnectionFailure.message(for: error)
        XCTAssertFalse(message.contains(secret))
        XCTAssertFalse(message.contains("private.example"))
        XCTAssertTrue(message.contains("-1011"))
        let unknown = NSError(domain: secret, code: 42, userInfo: [NSLocalizedDescriptionKey: secret])
        XCTAssertFalse(ConnectionFailure.message(for: unknown).contains(secret))
        XCTAssertTrue(ConnectionFailure.message(for: unknown).contains("42"))
    }
}
