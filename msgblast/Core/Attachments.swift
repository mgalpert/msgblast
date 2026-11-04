import Foundation
import UniformTypeIdentifiers

public struct MessageAttachment: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var filename: String
    public var path: String
    public var mimeType: String?
    public var byteCount: Int64?
    public init(id: String = UUID().uuidString, filename: String, path: String, mimeType: String? = nil, byteCount: Int64? = nil) {
        self.id = id; self.filename = filename; self.path = path; self.mimeType = mimeType; self.byteCount = byteCount
    }
    public var url: URL { URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }
    /// Whether a Messages attachment is something the person sent. iMessage app and rich link
    /// payloads (`.pluginPayloadAttachment`), empty transfers and hidden files are not shown.
    public static func isUserFile(filename: String, path: String, uti: String?, byteCount: Int64?) -> Bool {
        let plugin = "pluginPayloadAttachment"
        if uti?.caseInsensitiveCompare("com.apple.messages.\(plugin)") == .orderedSame { return false }
        for name in [filename, URL(fileURLWithPath: path).lastPathComponent] {
            if name.hasPrefix(".") || URL(fileURLWithPath: name).pathExtension.caseInsensitiveCompare(plugin) == .orderedSame { return false }
        }
        return byteCount != 0
    }
    public var isImage: Bool {
        mimeType?.hasPrefix("image/") == true || UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
    }
}

// Messages accepts text and files as separate sends. Each part keeps its own durable receipt.
public struct OutgoingPart: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var text: String?
    public var attachment: MessageAttachment?
    public var state: Submission = .ready
    public var baseline: Int64?
    public var attemptedAt: Date?
    public var anchor: Anchor?
    public var error: String?
    public init(text: String) { self.text = text }
    public init(attachment: MessageAttachment) { self.attachment = attachment }
    public func anchorCandidate(in messages: [Message], before: Int64? = nil, excluding: Set<String> = []) -> Message? {
        guard let baseline, let attemptedAt else { return nil }
        let candidates = messages.filter { message in
            guard message.outgoing, message.id > baseline, before.map({ message.id < $0 }) ?? true,
                  message.date >= attemptedAt.addingTimeInterval(-2), !excluding.contains(message.guid) else { return false }
            if let attachment {
                return message.attachments.contains {
                    $0.filename == attachment.filename && (attachment.byteCount == nil || $0.byteCount == attachment.byteCount)
                }
            }
            return message.text == text && message.attachments.isEmpty
        }
        return candidates.count == 1 ? candidates.first : nil
    }
}
public struct OutgoingPayload: Codable, Hashable, Sendable {
    public var parts: [OutgoingPart]
    public init(text: String, attachments: [MessageAttachment]) {
        parts = text.isEmpty ? [] : [OutgoingPart(text: text)]
        parts += attachments.map { OutgoingPart(attachment: $0) }
    }
    public var pendingIndices: [Int] { parts.indices.filter { [.ready, .failed].contains(parts[$0].state) } }
    public var submission: Submission {
        for state: Submission in [.uncertain, .sending, .failed, .ready] where parts.contains(where: { $0.state == state }) { return state }
        return .submitted
    }
    public var anchor: Anchor? { parts.compactMap(\.anchor).min { $0.rowID < $1.rowID } }
    public var error: String? { parts.compactMap(\.error).first }
    public var needsReconciliation: Bool { parts.contains { $0.anchor == nil && [.submitted, .uncertain].contains($0.state) } }
    public func recoveringInFlight() -> Self {
        var result = self
        for i in result.parts.indices where result.parts[i].state == .sending {
            result.parts[i].state = .uncertain
            result.parts[i].error = "Submission interrupted. Refresh to reconcile before resending."
        }
        return result
    }
    public mutating func reconcile(in messages: [Message], before: Int64? = nil, excluding: Set<String> = []) {
        var claimed = excluding.union(parts.compactMap(\.anchor?.guid))
        for i in parts.indices where parts[i].anchor == nil && [.submitted, .uncertain].contains(parts[i].state) {
            if let found = parts[i].anchorCandidate(in: messages, before: before, excluding: claimed) {
                parts[i].anchor = Anchor(rowID: found.id, guid: found.guid)
                parts[i].state = .submitted; parts[i].error = nil
                claimed.insert(found.guid)
            }
        }
    }
}

// A transport copy has a separate lifetime from the saved draft and each recipient.
public enum MessagesAttachmentStaging {
    public static func stage(_ attachment: MessageAttachment, in root: URL) throws -> URL {
        let files = FileManager.default
        if files.fileExists(atPath: root.path) {
            let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw AppFailure.blocked("The attachment staging folder is unavailable.") }
        } else {
            try files.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let source = attachment.url
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw AppFailure.blocked("The saved attachment is not a regular file.") }
        let directory = root.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let destination = directory.appendingPathComponent(source.lastPathComponent)
        do {
            try files.copyItem(at: source, to: destination)
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            return destination
        } catch {
            try? files.removeItem(at: directory)
            throw error
        }
    }
}
