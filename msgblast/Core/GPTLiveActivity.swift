import Combine
import Foundation

public struct GPTLiveActivityEntry: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let category: String
    public let summary: String
    public let detail: String?
    public let callID: String?

    var retainedBytes: Int {
        category.utf8.count + summary.utf8.count + (detail?.utf8.count ?? 0) + (callID?.utf8.count ?? 0) + 128
    }
}

/// Local, bounded session activity. Nothing is written to disk automatically.
@MainActor
public final class GPTLiveActivityLog: ObservableObject {
    @Published public var enabled = false {
        didSet {
            guard enabled != oldValue else { return }
            record(category: "debug", summary: enabled ? "Debug details enabled for future activity." : "Debug details disabled. Existing details remain until cleared.")
        }
    }
    @Published public private(set) var entries: [GPTLiveActivityEntry] = []
    @Published public private(set) var droppedEntryCount = 0
    public let maximumEntries: Int
    public let maximumBytes: Int
    private var retainedBytes = 0

    public init(maximumEntries: Int = 500, maximumBytes: Int = 512 * 1024) {
        self.maximumEntries = max(1, maximumEntries)
        self.maximumBytes = max(4096, maximumBytes)
    }

    public func record(category: String, summary: String, detail: String? = nil, callID: String? = nil) {
        let entry = GPTLiveActivityEntry(
            id: UUID(), timestamp: Date(),
            category: Self.sanitized(category, maximumBytes: 64),
            summary: Self.sanitized(summary, maximumBytes: 1024),
            detail: enabled ? detail.map { Self.sanitized($0, maximumBytes: min(32 * 1024, maximumBytes - 2048)) } : nil,
            callID: callID.map { Self.sanitized($0, maximumBytes: 256) }
        )
        entries.append(entry)
        retainedBytes += entry.retainedBytes
        while entries.count > maximumEntries || retainedBytes > maximumBytes {
            retainedBytes -= entries.removeFirst().retainedBytes
            droppedEntryCount += 1
        }
    }

    public func clear() {
        entries = []
        retainedBytes = 0
        droppedEntryCount = 0
    }

    /// Called only by an explicit copy/export action. Contains the same redacted entries shown in the UI.
    public func jsonExportData() throws -> Data {
        struct Export: Encodable {
            let formatVersion = 1
            let exportedAt: Date
            let debugEnabled: Bool
            let droppedEntryCount: Int
            let entries: [GPTLiveActivityEntry]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(Export(exportedAt: Date(), debugEnabled: enabled, droppedEntryCount: droppedEntryCount, entries: entries))
    }

    private static let sensitiveField = #"(?:authorization|proxy[-_]?authorization|api[-_]?key|access[-_]?token|refresh[-_]?token|client[-_]?secret|password|credential|audio|pcm|base64)"#
    private static let redactions: [(NSRegularExpression, String)] = [
        // Quoted JSON/log fields may include escaped quotes and newlines.
        (#"(?i)(["']?"# + sensitiveField + #"["']?\s*[:=]\s*)"(?:[^"\\]|\\.)*""#, "$1\"[redacted]\""),
        (#"(?i)(["']?"# + sensitiveField + #"["']?\s*[:=]\s*)'(?:[^'\\]|\\.)*'"#, "$1'[redacted]'"),
        (#"(?i)(["']?"# + sensitiveField + #"["']?\s*[:=]\s*)(?!["'])(?:Bearer\s+)?[^\s,;}\]]+"#, "$1[redacted]"),
        (#"(?i)\bBearer\s+[^\s\"',;<>\]}]+"#, "Bearer [redacted]"),
        (#"(?i)sk-[a-z0-9_-]+"#, "[redacted key]"),
        // Audio/base64 must never enter this log, including accidentally supplied bare blobs.
        (#"[A-Za-z0-9+/]{256,}={0,2}"#, "[redacted encoded data]"),
        (#"(?i)data:audio/[^,\s]+,[A-Za-z0-9+/=]+"#, "[redacted audio]")
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    static func sanitized(_ input: String, maximumBytes: Int) -> String {
        // Bound work even if a caller accidentally passes a very large payload. Redact after
        // clipping so a credential crossing the boundary is still removed in its entirety.
        var text = utf8Prefix(input, maximumBytes: 256 * 1024)
        if let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
           let scrubbed = try? JSONSerialization.data(withJSONObject: scrubJSON(object), options: [.fragmentsAllowed, .prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
           let json = String(data: scrubbed, encoding: .utf8) { text = json }
        for (expression, replacement) in redactions {
            text = expression.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: replacement)
        }
        let wasClipped = text.utf8.count > maximumBytes || input.utf8.count > 256 * 1024
        let marker = "\n[truncated]"
        return wasClipped ? utf8Prefix(text, maximumBytes: max(0, maximumBytes - marker.utf8.count)) + marker : text
    }

    private static let excludedFields: Set<String> = [
        "authorization", "proxyauthorization", "apikey", "accesstoken", "refreshtoken",
        "clientsecret", "password", "credential", "credentials", "audio", "inputaudio", "outputaudio", "pcm", "base64"
    ]

    private static func scrubJSON(_ value: Any, depth: Int = 0) -> Any {
        guard depth < 64 else { return "[redacted nested data]" }
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: [String: Any]()) { result, item in
                let field = item.key.lowercased().filter { $0.isLetter || $0.isNumber }
                result[item.key] = excludedFields.contains(field) ? "[redacted]" : scrubJSON(item.value, depth: depth + 1)
            }
        }
        if let array = value as? [Any] { return array.map { scrubJSON($0, depth: depth + 1) } }
        return value
    }

    private static func utf8Prefix(_ text: String, maximumBytes: Int) -> String {
        guard text.utf8.count > maximumBytes else { return text }
        var end = text.unicodeScalars.startIndex
        var bytes = 0
        for scalar in text.unicodeScalars {
            let count = scalar.utf8.count
            guard bytes + count <= maximumBytes else { break }
            bytes += count
            end = text.unicodeScalars.index(after: end)
        }
        return String(text[..<end])
    }
}
