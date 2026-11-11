import Foundation
import UniformTypeIdentifiers
import msgblastRemoteProtocol

/// A link found in a turn's text, for the Details sheet's Links section.
public struct SharedLink: Equatable, Identifiable, Sendable {
    public var id: String { "\(turnID)#\(url.absoluteString)" }
    public var url: URL
    public var turnID: String
    /// nil for your own messages.
    public var agentID: String?
    public var date: Date?
    /// The first line of the message the link came from.
    public var context: String
    public var host: String { url.host(percentEncoded: false).map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? url.absoluteString }
}

/// One attachment of a turn, for the Photos and Documents sections and inline thumbnails.
public struct SharedAttachment: Equatable, Identifiable, Sendable {
    public var id: String { "\(turnID)#\(index)" }
    public var turnID: String
    public var index: Int
    public var filename: String
    public var mimeType: String?
    public var byteCount: Int64?
    public var agentID: String?
    public var date: Date?
    public var isImage: Bool { SharedContent.isImage(filename: filename, mimeType: mimeType) }
    public init(turnID: String, index: Int, filename: String, mimeType: String?, byteCount: Int64?, agentID: String?, date: Date?) {
        self.turnID = turnID; self.index = index; self.filename = filename; self.mimeType = mimeType; self.byteCount = byteCount; self.agentID = agentID; self.date = date
    }
}

/// Pure helpers behind the shared-content lists.
public enum SharedContent {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Web links in text, with their ranges, in order. Only http and https are kept.
    public static func links(in text: String) -> [(range: Range<String.Index>, url: URL)] {
        guard let detector else { return [] }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let url = match.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let range = Range(match.range, in: text) else { return nil }
            return (range, url)
        }
    }

    /// Messages shows a message of one to three emoji, and nothing else, at a large size
    /// without a bubble. ZWJ sequences, skin tones and flags count as one emoji each.
    public static func isEmojiOnly(_ text: String) -> Bool {
        let characters = text.filter { !$0.isWhitespace }
        guard (1...3).contains(characters.count) else { return false }
        return characters.allSatisfy { character in
            guard let first = character.unicodeScalars.first, first.properties.isEmoji else { return false }
            // A digit or # is "emoji" only with a presentation selector or keycap.
            return first.properties.isEmojiPresentation || character.unicodeScalars.count > 1
        }
    }

    /// An image by MIME type, else by the filename's type.
    public static func isImage(filename: String, mimeType: String?) -> Bool {
        if let mimeType, mimeType.lowercased().hasPrefix("image/") { return true }
        let ext = (filename as NSString).pathExtension
        return !ext.isEmpty && UTType(filenameExtension: ext)?.conforms(to: .image) == true
    }
}

/// The tapbacks on one bubble as Messages stacks them: up to three distinct emoji, newest
/// last, and the total when more reactions than that were made.
public struct ReactionSummary: Equatable, Sendable {
    public var emoji: [String]
    public var total: Int
    /// Shown beside the stack when it hides some reactions.
    public var countLabel: String? { total > emoji.count ? "\(total)" : nil }
}

extension ProjectionPresenter {
    public func reactionSummary(for turn: RemoteTurn) -> ReactionSummary? {
        guard let reactions = turn.reactions, !reactions.isEmpty else { return nil }
        var distinct: [String] = []
        for reaction in reactions.reversed() where !distinct.contains(reaction.emoji) { distinct.append(reaction.emoji) }
        return ReactionSummary(emoji: Array(distinct.prefix(3).reversed()), total: reactions.count)
    }

    /// Photos, links and documents shared in a conversation, oldest first.
    public func sharedContent(in conversation: UUID) -> (photos: [SharedAttachment], links: [SharedLink], documents: [SharedAttachment]) {
        var photos: [SharedAttachment] = [], links: [SharedLink] = [], documents: [SharedAttachment] = []
        var seenLinks: Set<String> = []
        for turn in turns(in: conversation, agentID: nil) {
            let sender = turn.role == .user ? nil : turn.agentID
            for (index, file) in turn.attachments.enumerated() {
                let shared = SharedAttachment(turnID: turn.id, index: index, filename: file.filename, mimeType: file.mimeType, byteCount: file.byteCount, agentID: sender, date: turn.created)
                if shared.isImage { photos.append(shared) } else { documents.append(shared) }
            }
            let firstLine = turn.text.components(separatedBy: .newlines).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
            for link in SharedContent.links(in: turn.text) where seenLinks.insert(link.url.absoluteString).inserted {
                links.append(SharedLink(url: link.url, turnID: turn.id, agentID: sender, date: turn.created, context: firstLine))
            }
        }
        return (photos, links, documents)
    }
}
