import Foundation

public enum TranscriptChannel: String, Sendable { case source, translation }

/// Independent rolling captions, not fabricated speaker turns or sentence pairs.
/// Append provider deltas verbatim: do not add spaces, infer turn boundaries, or
/// deduplicate repeated words. Only identical event IDs are duplicates.
public struct TranscriptBuffer: Sendable {
    public private(set) var source = ""
    public private(set) var translation = ""
    private let characterLimit: Int
    private var eventIDs: [String] = []
    private var seen: Set<String> = []

    public init(characterLimit: Int = 1_200) {
        precondition(characterLimit > 0)
        self.characterLimit = characterLimit
    }

    public mutating func append(_ delta: String, to channel: TranscriptChannel, eventID: String?) {
        if let id = eventID {
            guard seen.insert(id).inserted else { return }
            eventIDs.append(id)
            if eventIDs.count > 512 { seen.remove(eventIDs.removeFirst()) }
        }
        switch channel {
        case .source: source = String((source + delta).suffix(characterLimit))
        case .translation: translation = String((translation + delta).suffix(characterLimit))
        }
    }
}
