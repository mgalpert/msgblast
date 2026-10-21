import ApplicationServices
import Darwin
import Foundation

public struct MuseSideChatBinding: Codable, Equatable, Sendable {
    public let comparisonID: UUID
    public let threadID: UUID?
    public var title: String
    public var url: URL? { threadID.flatMap { URL(string: "https://muse.ai/thread/\($0.uuidString.lowercased())") } }

    public init(comparisonID: UUID, threadID: UUID?, title: String) {
        self.comparisonID = comparisonID; self.threadID = threadID; self.title = title
    }
    static func threadID(in url: URL) -> UUID? {
        guard url.scheme == "https", url.host == "muse.ai", url.port == nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].isEmpty, parts[1] == "thread" else { return nil }
        return UUID(uuidString: String(parts[2]))
    }
    static let newURL = URL(string: "https://muse.ai/thread/new")!
}

struct MuseAppMessage: Codable, Equatable, Sendable {
    enum Role: String, Codable, Sendable { case user, assistant }
    let role: Role
    let text: String
}

struct MuseAppObservation: Codable, Sendable {
    var url: URL
    var draft: String
    var composerFocused: Bool
    var messages: [MuseAppMessage]
    var composerIdentity: UInt?
    var sidebarOpen = false
    var windowBounds: DesktopAppSnapshot.Bounds?
    var generating: Bool = false
    var title: String = "Muse side chat"
}

// WebKit's compound composer has an empty AXValue even when it contains text.
// AXStringForRange reads its real contents without focusing or editing it.
// Muse's WebKit counts visible characters rather than UTF-16 units; standard
// native fields can use UTF-16. The discovered endpoint, not a guessed unit,
// bounds the read. The returned string still has a strict UTF-16 size limit.
enum MuseTextRange {
    static func read(maximumUTF16: Int = 200_000, query: (NSRange) throws -> String?) throws -> String {
        var observed: [Int: String] = [:]
        func read(_ length: Int) throws -> String {
            guard let value = try query(NSRange(location: 0, length: length)),
                  observed[length] == nil || observed[length] == value else {
                throw DesktopAppError.unavailable("Muse's draft could not be read consistently. It was preserved.")
            }
            observed[length] = value
            return value
        }
        guard maximumUTF16 > 0, try read(0) == "" else {
            throw DesktopAppError.unavailable("Muse's draft text range is unavailable.")
        }
        var lower = 0, upper = 1
        while try !read(upper).isEmpty {
            guard upper <= maximumUTF16 else { throw DesktopAppError.unavailable("Muse's draft exceeds the safe read limit. It was preserved.") }
            lower = upper; upper = min(upper * 2, maximumUTF16 + 1)
        }
        while upper - lower > 1 {
            let middle = (lower + upper) / 2
            if try read(middle).isEmpty { upper = middle } else { lower = middle }
        }
        let text = try read(lower)
        guard [text.count, text.unicodeScalars.count, text.utf16.count].contains(lower), text.utf16.count <= maximumUTF16, try read(lower + 1).isEmpty,
              try read(lower) == text else { throw DesktopAppError.unavailable("Muse's draft changed while it was being read.") }
        return text
    }
}

enum MuseComposerText {
    static func read(markerText: () throws -> String?, query: (NSRange) throws -> String?) throws -> String {
        guard let marker = try markerText() else { throw DesktopAppError.unavailable("Muse's composer text markers are unavailable.") }
        func isPlaceholder(_ value: String) -> Bool {
            value.hasPrefix("Message") && value.dropFirst(7).allSatisfy { $0 == "\n" }
        }
        if isPlaceholder(marker) {
            // The empty compound button exposes its placeholder and adjacent
            // controls. A literal draft "Message" has an empty marker range
            // and a seven-character numeric range instead.
            let prefix = try query(NSRange(location: 0, length: 8))
            guard try query(NSRange(location: 0, length: 7)) == "Message",
                  let prefix, prefix.count > 7, isPlaceholder(prefix),
                  try query(NSRange(location: 0, length: 8)) == prefix,
                  try markerText() == marker else { throw DesktopAppError.unavailable("Muse's empty composer could not be confirmed.") }
            return ""
        }
        guard marker.isEmpty else { throw DesktopAppError.unavailable("Muse's composer layout is unsupported. Its draft was preserved.") }
        let draft = try MuseTextRange.read(query: query)
        guard try markerText() == marker else { throw DesktopAppError.unavailable("Muse's composer changed while reading its draft.") }
        return draft
    }
}

struct MuseAXNode: Sendable {
    let role: String
    var label: String = ""
    var value: String = ""
    var children: [MuseAXNode] = []
    var descendants: [MuseAXNode] { [self] + children.flatMap(\.descendants) }
}

enum MuseTranscript {
    static func messages(in root: MuseAXNode) throws -> [MuseAppMessage] {
        guard root.role == "AXGroup", root.label == "Chat messages" else {
            throw DesktopAppError.unavailable("Muse's message boundary is unavailable.")
        }
        return try root.children.compactMap { group in
            let nodes = group.descendants
            let text = nodes.filter { $0.role == "AXStaticText" }.map(\.value)
            if group.children.first?.role == "AXStaticText", group.children.first?.value == "You:" {
                let body = text.dropFirst().joined(separator: "\n\n")
                guard !body.isEmpty else { throw DesktopAppError.unavailable("Muse exposed an incomplete outgoing message.") }
                return MuseAppMessage(role: .user, text: body)
            }
            if nodes.contains(where: { $0.role == "AXPopUpButton" && $0.label == "React" }) {
                let body = text.joined(separator: "\n\n")
                guard !body.isEmpty else { return nil }
                return MuseAppMessage(role: .assistant, text: body)
            }
            // Earlier messages can use a single accessible text node.
            if text.count == 1, let value = text.first {
                for (prefix, role) in [("User message: ", MuseAppMessage.Role.user), ("Assistant message: ", .assistant)] where value.hasPrefix(prefix) {
                    return MuseAppMessage(role: role, text: String(value.dropFirst(prefix.count)))
                }
            }
            return nil
        }
    }
}

struct MuseAppReceipt {
    let baseline: [MuseAppMessage]
    let prompt: String
    func reply(in messages: [MuseAppMessage]) throws -> String? {
        guard messages.starts(with: baseline) else {
            throw DesktopAppError.unavailable("Muse's message history changed while waiting. Review the side chat before continuing.")
        }
        let added = messages.dropFirst(baseline.count)
        guard !added.isEmpty else { return nil }
        guard added.first == MuseAppMessage(role: .user, text: prompt), added.dropFirst().allSatisfy({ $0.role == .assistant }) else {
            throw DesktopAppError.unavailable("Another request appeared in Muse. No reply was attributed to this comparison.")
        }
        let answer = added.dropFirst().map(\.text).joined(separator: "\n\n")
        return answer.isEmpty ? nil : answer
    }
}


enum MuseNativeReader {
    static func capture(_ target: DesktopAppConversation.Target) throws -> MuseAppObservation {
        guard AXIsProcessTrusted() else { throw DesktopAppError.unavailable("Grant msgblast Accessibility permission to read Muse's side-chat identity and draft.") }
        func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
        }
        func string(_ element: AXUIElement, _ key: String) -> String { attribute(element, key) as? String ?? "" }
        guard let window = DesktopNativeWindowLookup.resolve(target) else {
            throw DesktopAppError.unavailable("Muse's window could not be read safely. Dismiss any dialogs and connect again; no message was sent.")
        }
        func windowBounds() throws -> DesktopAppSnapshot.Bounds {
            guard let position = attribute(window, "AXPosition"), CFGetTypeID(position) == AXValueGetTypeID(),
                  let size = attribute(window, "AXSize"), CFGetTypeID(size) == AXValueGetTypeID() else {
                throw DesktopAppError.unavailable("Muse's native window geometry is unavailable.")
            }
            var point = CGPoint.zero, dimensions = CGSize.zero
            guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else {
                throw DesktopAppError.unavailable("Muse's native window geometry is unreadable.")
            }
            return .init(x: point.x, y: point.y, width: dimensions.width, height: dimensions.height)
        }
        let initialBounds = try windowBounds()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        var count = 0, webAreas: [AXUIElement] = [], composers: [AXUIElement] = [], messageRoots: [MuseAXNode] = []
        var initialURL: URL?
        func walk(_ element: AXUIElement, depth: Int) throws -> MuseAXNode {
            count += 1
            guard count <= 6000, depth <= 60, ContinuousClock.now < deadline else {
                throw DesktopAppError.unavailable("Muse's accessibility tree could not be read completely.")
            }
            let role = string(element, "AXRole")
            let title = string(element, "AXTitle")
            let label = title.isEmpty ? string(element, "AXDescription") : title
            guard role != "AXSheet", role != "AXDialog" else { throw DesktopAppError.unavailable("Dismiss Muse's dialog before continuing.") }
            if role == "AXWebArea" { webAreas.append(element); initialURL = attribute(element, "AXURL") as? URL }
            if (["AXTextArea", "AXTextField"].contains(role) && label == "Message") ||
                (role == "AXButton" && ["Message Attach file Dictate a message Send", "Message Attach file Dictate a message Stop"].contains(label)) { composers.append(element) }
            let children = try (attribute(element, "AXChildren") as? [AXUIElement] ?? []).map { try walk($0, depth: depth + 1) }
            let node = MuseAXNode(role: role, label: label, value: string(element, "AXValue"), children: children)
            if role == "AXGroup", label == "Chat messages" { messageRoots.append(node) }
            return node
        }
        let tree = try walk(window, depth: 0)
        guard webAreas.count == 1, composers.count == 1, messageRoots.count == 1,
              let web = webAreas.first, let composer = composers.first else {
            throw DesktopAppError.unavailable("Muse's side chat and composer could not be read independently. Nothing will be sent.")
        }
        func url() throws -> URL {
            guard let url = attribute(web, "AXURL") as? URL,
                  url == URL(string: "https://muse.ai/") || url == MuseSideChatBinding.newURL || MuseSideChatBinding.threadID(in: url) != nil else {
                throw DesktopAppError.unavailable("Muse's current chat address is unavailable or unsupported.")
            }
            return url
        }
        let before = try url()
        guard initialURL == before else { throw DesktopAppError.unavailable("Muse navigated while its messages were being read.") }
        func parameter(_ key: String, _ argument: CFTypeRef) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyParameterizedAttributeValue(composer, key as CFString, argument, &value) == .success ? value : nil
        }
        let draft = try MuseComposerText.read(markerText: {
            guard let range = parameter("AXTextMarkerRangeForUIElement", composer) else { return nil }
            return parameter("AXStringForTextMarkerRange", range) as? String
        }) { range in
            var native = CFRange(location: range.location, length: range.length)
            guard let rangeValue = AXValueCreate(.cfRange, &native) else { return nil }
            return parameter("AXStringForRange", rangeValue) as? String
        }
        guard try url() == before, try windowBounds() == initialBounds else { throw DesktopAppError.unavailable("Muse navigated or moved while its draft was being read.") }
        let app = AXUIElementCreateApplication(pid_t(target.pid))
        AXUIElementSetMessagingTimeout(app, 0.2)
        let focus = attribute(app, "AXFocusedUIElement")
        let nodes = tree.descendants
        let header = nodes.first { $0.role == "AXButton" && $0.label.contains("Open chat and side chats") }?.label
        let title = header.map { $0.components(separatedBy: " Unread chats").first ?? $0 } ?? "Muse side chat"
        return MuseAppObservation(url: before, draft: draft, composerFocused: focus.map { CFEqual($0, composer) } ?? false,
                                  messages: try MuseTranscript.messages(in: messageRoots[0]),
                                  composerIdentity: CFHash(composer),
                                  sidebarOpen: nodes.contains { $0.role == "AXButton" && $0.label == "New side chat" },
                                  windowBounds: initialBounds,
                                  generating: nodes.contains { $0.label == "Stop" || $0.label.hasSuffix(" Dictate a message Stop") }, title: title)
    }
}
