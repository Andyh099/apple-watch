import Foundation

// No XCTest/Testing dependency: usable with Command Line Tools alone.
@main
struct CoreSmoke {
    static func main() {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ description: String) {
            precondition(value(), description)
            count += 1
        }
        var framer = AudioFrameBuffer()
        check(framer.append(Data(repeating: 0, count: 4_799)).isEmpty, "partial silence buffered")
        check(framer.append(Data([0])).first == Data(repeating: 0, count: 4_800), "silence preserved")
        let original = Data((0..<20_007).map { UInt8($0 % 253) })
        var output = Data()
        for offset in stride(from: 0, to: original.count, by: 97) {
            for frame in framer.append(original.subdata(in: offset..<min(original.count, offset + 97))) {
                output.append(frame)
            }
        }
        output.append(framer.flush())
        check(output == original.prefix(20_006), "PCM bytes ordered across arbitrary boundaries")
        check(framer.append(Data([42])).isEmpty, "odd-byte completion buffered")
        check(framer.flush() == Data([original.last!, 42]), "trailing sample retained")
        var captions = TranscriptBuffer(characterLimit: 10)
        captions.append("No", to: .source, eventID: "1")
        captions.append(", no", to: .source, eventID: "2")
        captions.append(", no", to: .source, eventID: "2")
        captions.append("不是，不是", to: .translation, eventID: "3")
        check(captions.source == "No, no", "intentional repeats kept, duplicate event ignored")
        check(captions.translation == "不是，不是", "source and translation independent")
        captions.append("1234567890123", to: .translation, eventID: nil)
        check(captions.translation == "4567890123", "caption memory bounded")
        for endpoint in ["ws://example.com/interpret", "https://example.com/interpret", "wss://u:p@example.com/interpret", "wss://example.com/interpret?token=x", "wss://example.com/interpret#x", "wss://example.com/other"] {
            check(SessionConfiguration(endpoint: endpoint, token: "device").validatedURL == nil, "reject insecure/malformed endpoint")
        }
        check(SessionConfiguration(endpoint: "wss://example.com/interpret", token: "device").validatedURL != nil, "accept encrypted relay")
        check(SessionConfiguration(endpoint: "wss://example.com/interpret", token: "bad\nheader").validatedURL == nil, "reject header injection")
        for token in ["bad\u{0}header", "bad\theader", "bad\u{7f}header"] {
            check(SessionConfiguration(endpoint: "wss://example.com/interpret", token: token).validatedURL == nil, "reject control characters")
        }
        print("PASS: \(count) core smoke assertions (real Swift compilation; no voice-service calls).")
    }
}
