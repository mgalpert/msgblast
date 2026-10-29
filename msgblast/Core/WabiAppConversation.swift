import Foundation
import CryptoKit

enum WabiThread {
    static func isValid(_ url: URL) -> Bool {
        guard url.scheme == "wabi", url.host == "app", url.port == nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return false }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath.range(of: #"^/threads/[0-9a-f]{24}$"#, options: .regularExpression) != nil
    }
    static func verifiedURL(_ url: URL?, currentURL: URL?, webAreaCount: Int, composerCount: Int, purpose: WabiReadPurpose) throws -> URL {
        guard webAreaCount <= 1, composerCount <= 1 else {
            throw DesktopAppError.unavailable("Wabi's chat address could not be verified.")
        }
        if purpose == .readiness, webAreaCount == 0 || url == nil || url?.absoluteString == "about:blank" || url?.absoluteString == "wabi://app/" || url?.absoluteString == "wabi://app" {
            throw WabiObservationError.transient("Wabi is still opening its chat. Wait for it to finish loading.")
        }
        guard webAreaCount == 1, let url, isValid(url), currentURL == url else {
            throw DesktopAppError.unavailable("Wabi's chat address could not be verified.")
        }
        return url
    }

}

struct WabiAppMessage: Codable, Equatable, Sendable {
    enum Role: String, Codable, Sendable { case user, assistant }
    let role: Role
    let text: String
    // Keep the original AX text for existing receipt digests. Presentation is
    // transient and never changes message identity or persisted receipt bytes.
    var presentation: String? = nil
    private enum CodingKeys: String, CodingKey { case role, text }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.role == rhs.role && lhs.text == rhs.text }
}

private enum WabiHistoryWindow {
    // Bound receipt size and hashing work for unusually long native chats.
    static let maximumDropped = 16
    static func minimumRetained(_ count: Int) -> Int { max(3, count / 2 + count % 2) }
    static func canonical(_ messages: [WabiAppMessage]) -> [WabiAppMessage] {
        messages.map { .init(role: $0.role, text: $0.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")) }
    }
    // Wabi may omit one older accessible row while keeping the newest rows.
    // Require a substantial exact overlap and an intact recent tail.
    static func matchesMissingOlderRow<T: Equatable>(baseline: [T], observed: [T]) -> Bool {
        // A short chat may lose one middle row when Wabi virtualizes it.
        // Retain both endpoints and require a unique exact deletion.
        if (3...6).contains(baseline.count), observed.count == baseline.count - 1,
           baseline.first == observed.first, baseline.last == observed.last {
            let matches = (1..<(baseline.count - 1)).filter { index in
                Array(baseline.prefix(index)) + Array(baseline.dropFirst(index + 1)) == observed
            }
            if matches.count == 1 { return true }
        }
        guard baseline.count >= 7, observed.count >= minimumRetained(baseline.count),
              observed.count >= 6, baseline.count > observed.count,
              baseline.suffix(3).elementsEqual(observed.suffix(3)) else { return false }
        let dropped = baseline.count - observed.count - 1
        guard dropped >= 0, dropped + 1 <= maximumDropped else { return false }
        let window = Array(baseline.dropFirst(dropped).dropLast(3))
        let visible = Array(observed.dropLast(3))
        var index = 0
        while index < visible.count && window[index] == visible[index] { index += 1 }
        return window.dropFirst(index + 1).elementsEqual(visible.dropFirst(index))
    }
}

struct WabiAXNode: Sendable {
    let role: String
    var label = ""
    var value = ""
    var classes: [String] = []
    var children: [WabiAXNode] = []
    var descendants: [WabiAXNode] { [self] + children.flatMap(\.descendants) }
}

enum WabiObservationError: LocalizedError, Sendable {
    case transient(String)
    var errorDescription: String? { switch self { case .transient(let message): message } }
}

enum WabiReadPurpose: Sendable { case readiness, conversation, sentWaiting }

enum WabiNativeMessages {
    private static func listText(_ list: WabiAXNode) -> String? {
        let pieces = list.descendants.filter { ["AXListMarker", "AXStaticText"].contains($0.role) }
        var items: [String] = []
        var current: String?
        for piece in pieces {
            let value = piece.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            if piece.role == "AXListMarker" {
                if let current { items.append(current) }
                current = value
            } else {
                guard var item = current else { return nil }
                let punctuation = ".,;:!?%)]}”’".contains(value.first!)
                let opening = "([{“‘".contains(item.last!)
                item += (punctuation || opening ? "" : " ") + value
                current = item
            }
        }
        if let current { items.append(current) }
        return items.isEmpty ? nil : items.joined(separator: "\n")
    }
    private static func presentation(_ frame: WabiAXNode, timestamp: String) -> String? {
        var blocks: [String] = []
        var sawList = false
        func collect(_ node: WabiAXNode) {
            if node.role == "AXList", let list = listText(node) {
                sawList = true; blocks.append(list); return
            }
            if node.role == "AXStaticText" { blocks.append(node.value); return }
            for child in node.children { collect(child) }
        }
        collect(frame)
        guard sawList, blocks.last == timestamp else { return nil }
        blocks.removeLast()
        return blocks.joined(separator: "\n\n")
    }
    static func read(_ root: WabiAXNode, purpose: WabiReadPurpose = .conversation) throws -> [WabiAppMessage] {
        guard purpose != .readiness else { return [] }
        let nodes = root.descendants
        // Wabi 0.1.11 and 0.1.15 expose sender-specific message frames through native
        // AXDOMClassList. Refuse unknown frames rather than infer a speaker
        // from text, position, color, or a delivery receipt.
        let frameClasses: Set<String> = ["x1n2onr6", "x193iq5w", "x67m8t7", "xc90arz", "xza2g2e"]
        var frames = nodes.filter { $0.role == "AXGroup" && frameClasses.isSubset(of: Set($0.classes)) }
        let reactions = nodes.filter { $0.role == "AXPopUpButton" && $0.label == "Add reaction" }.count
        // While Wabi prepares a reply, its AX tree can contain an empty
        // assistant frame after the complete outgoing message. Ignore only
        // that trailing placeholder: it is not a reply, and every preceding
        // frame must still have its own reaction control.
        if purpose == .sentWaiting, frames.count >= 2, frames.count == reactions + 1,
           let pending = frames.last, let outgoing = frames.dropLast().last,
           pending.classes.contains("xqcrz7y"), !pending.classes.contains("xpvyfi4"),
           outgoing.classes.contains("xpvyfi4"), !outgoing.classes.contains("xqcrz7y"),
           !pending.descendants.contains(where: { $0.role == "AXStaticText" || ($0.role == "AXPopUpButton" && $0.label == "Add reaction") }),
           frames.dropLast().allSatisfy({ frame in
               frame.descendants.filter { $0.role == "AXPopUpButton" && $0.label == "Add reaction" }.count == 1
           }) {
            frames.removeLast()
        }
        guard !frames.isEmpty, frames.count == reactions else {
            throw WabiObservationError.transient("Wabi's messages are still updating. No sender or reply was inferred.")
        }
        return try frames.map { frame in
            let own = frame.classes.contains("xpvyfi4"), other = frame.classes.contains("xqcrz7y")
            var text = frame.descendants.filter { $0.role == "AXStaticText" }.map(\.value)
            guard own != other else { throw DesktopAppError.unavailable("Wabi's message sender is unavailable. No reply was attributed.") }
            guard text.count >= 2, let timestamp = text.last,
                  timestamp.range(of: #"^\d{1,2}:\d{2}\s*[AP]M$"#, options: .regularExpression) != nil else {
                throw WabiObservationError.transient("Wabi's message boundary is still updating. No reply was attributed.")
            }
            text.removeLast()
            let body = text.joined(separator: "\n\n")
            guard !body.isEmpty else { throw WabiObservationError.transient("Wabi's message body is still updating. No reply was attributed.") }
            return WabiAppMessage(role: own ? .user : .assistant, text: body,
                                  presentation: presentation(frame, timestamp: timestamp))
        }
    }
}

struct WabiAppObservation: Codable, Sendable {
    struct Link: Codable, Equatable, Sendable { let label: String; let url: URL }
    let url: URL
    let draft: String?
    let links: [Link]
    let messages: [WabiAppMessage]
    var composerFocused: Bool? = nil
}

struct WabiAppReceipt {
    let baseline: [WabiAppMessage]
    let prompt: String

    private var acceptableHistory: [[WabiAppMessage]] {
        let orientations = [baseline, Array(baseline.reversed())]
        let greeting = WabiAppMessage(role: .assistant, text: "What can I do for you?")
        let withoutGreeting = orientations.compactMap { history in
            history.count >= 3 && history.first == greeting ? Array(history.dropFirst()) : nil
        }
        // Wabi virtualizes older messages. Compare at least half of the
        // original history and at least three consecutive messages, including
        // every sender, before accepting a shifted window.
        let minimum = WabiHistoryWindow.minimumRetained(baseline.count)
        let shifted = orientations.flatMap { history -> [[WabiAppMessage]] in
            guard history.count > minimum else { return [] }
            let limit = min(WabiHistoryWindow.maximumDropped, history.count - minimum)
            return (1...limit).map { Array(history.dropFirst($0)) }
        }
        return orientations + withoutGreeting + shifted
    }

    func unchanged(_ messages: [WabiAppMessage]) -> Bool {
        let observed = WabiHistoryWindow.canonical(messages)
        return acceptableHistory.map(WabiHistoryWindow.canonical).contains(observed) || acceptableHistory.map(WabiHistoryWindow.canonical).contains(Array(observed.reversed())) ||
            [baseline, Array(baseline.reversed())].contains { history in
                WabiHistoryWindow.matchesMissingOlderRow(baseline: WabiHistoryWindow.canonical(history), observed: observed) ||
                    WabiHistoryWindow.matchesMissingOlderRow(baseline: WabiHistoryWindow.canonical(history), observed: Array(observed.reversed()))
            }
    }

    func reply(in messages: [WabiAppMessage]) throws -> String? {
        if unchanged(messages) { return nil }
        guard messages.count <= baseline.count + 2 else {
            throw DesktopAppError.unavailable("Wabi's message history changed or another message arrived. Review the saved chat; no reply was attributed.")
        }
        // Wabi can reverse its accessible message order when reopening a chat.
        // Keep history and sender exact. Wabi flattens outgoing line breaks in
        // its rendered history; the pre-send native draft was checked exactly.
        var candidates: Set<String> = []
        var waiting = false
        for ordered in [messages, Array(messages.reversed())] {
            for oldCount in max(0, ordered.count - 2)...ordered.count {
                let old = Array(ordered.prefix(oldCount))
                guard [baseline, Array(baseline.reversed())].contains(where: { WabiHistoryWindow.matchesMissingOlderRow(baseline: WabiHistoryWindow.canonical($0), observed: WabiHistoryWindow.canonical(old)) }) else { continue }
                let added = ordered.dropFirst(oldCount)
                guard let outgoing = added.first, outgoing.role == .user,
                      outgoing.text.split(whereSeparator: \.isWhitespace) == prompt.split(whereSeparator: \.isWhitespace) else { continue }
                if added.count == 1 { waiting = true }
                else if let answer = added.last, answer.role == .assistant { candidates.insert(answer.presentation ?? answer.text) }
            }
            for old in acceptableHistory where WabiHistoryWindow.canonical(ordered).starts(with: WabiHistoryWindow.canonical(old)) {
                let added = ordered.dropFirst(old.count)
                guard added.count <= 2 else { continue }
                guard let outgoing = added.first, outgoing.role == .user,
                      outgoing.text.split(whereSeparator: \.isWhitespace) == prompt.split(whereSeparator: \.isWhitespace) else { continue }
                if added.count == 1 { waiting = true }
                else if let answer = added.last, answer.role == .assistant { candidates.insert(answer.presentation ?? answer.text) }
            }
        }
        guard candidates.count <= 1 else { throw DesktopAppError.unavailable("Wabi's new reply is ambiguous. Review the saved chat.") }
        if let answer = candidates.first { return answer }
        if waiting { return nil }
        throw DesktopAppError.unavailable("Wabi's new message did not match this request. No reply was attributed.")
    }
}

// Persist only a digest of the prior chat, so a late response can be matched
// without saving the user's unrelated native conversation in msgblast.
struct WabiHistoryDigest: Codable, Equatable, Sendable {
    let retained: Int
    let digest: Data
}

struct WabiReplyReceipt: Codable, Equatable, Sendable {
    var version = 1
    let comparisonID: UUID
    let url: URL
    let prompt: String
    let baselineCount: Int
    let baselineDigest: Data
    let reversedBaselineDigest: Data
    // Optional for backwards compatibility. Digests retain no message text.
    let overlapDigests: [WabiHistoryDigest]?
    // Optional per-row hashes allow one older virtualized row to disappear.
    let messageDigests: [Data]?
    // Optional canonical digests let new receipts survive Wabi changing only
    // whitespace or word-node boundaries. Older raw digests remain readable.
    let canonicalBaselineDigest: Data?
    let canonicalReversedBaselineDigest: Data?
    let canonicalOverlapDigests: [WabiHistoryDigest]?
    let canonicalMessageDigests: [Data]?
    var automaticRecovery = true

    init(comparisonID: UUID, url: URL, prompt: String, baseline: [WabiAppMessage]) throws {
        self.comparisonID = comparisonID; self.url = url; self.prompt = prompt
        baselineCount = baseline.count
        baselineDigest = try Self.digest(baseline)
        reversedBaselineDigest = try Self.digest(Array(baseline.reversed()))
        messageDigests = baseline.count <= 512 ? try baseline.map { try Self.digest([$0]) } : nil
        let canonical = WabiHistoryWindow.canonical(baseline)
        canonicalBaselineDigest = try Self.digest(canonical)
        canonicalReversedBaselineDigest = try Self.digest(Array(canonical.reversed()))
        canonicalMessageDigests = baseline.count <= 512 ? try canonical.map { try Self.digest([$0]) } : nil
        let minimum = WabiHistoryWindow.minimumRetained(baseline.count)
        var overlaps: [WabiHistoryDigest] = []
        if baseline.count > minimum {
            for history in [baseline, Array(baseline.reversed())] {
                let limit = min(WabiHistoryWindow.maximumDropped, history.count - minimum)
                for drop in 1...limit {
                    let suffix = Array(history.dropFirst(drop))
                    overlaps.append(.init(retained: suffix.count, digest: try Self.digest(suffix)))
                }
            }
        }
        overlapDigests = overlaps
        var canonicalOverlaps: [WabiHistoryDigest] = []
        if canonical.count > minimum {
            for history in [canonical, Array(canonical.reversed())] {
                let limit = min(WabiHistoryWindow.maximumDropped, history.count - minimum)
                for drop in 1...limit {
                    let suffix = Array(history.dropFirst(drop))
                    canonicalOverlaps.append(.init(retained: suffix.count, digest: try Self.digest(suffix)))
                }
            }
        }
        canonicalOverlapDigests = canonicalOverlaps
    }

    private static func digest(_ messages: [WabiAppMessage]) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return Data(SHA256.hash(data: try encoder.encode(messages)))
    }

    func reply(in messages: [WabiAppMessage], knownHistory: [WabiAppMessage]? = nil) throws -> String? {
        guard version == 1, WabiThread.isValid(url), !prompt.isEmpty, baselineCount >= 0,
              baselineDigest.count == 32, reversedBaselineDigest.count == 32,
              messages.count <= baselineCount || messages.count - baselineCount <= 2 else {
            throw DesktopAppError.unavailable("Wabi's saved chat could not be verified.")
        }
        if let overlapDigests {
            let minimum = WabiHistoryWindow.minimumRetained(baselineCount)
            guard overlapDigests.count <= 2 * WabiHistoryWindow.maximumDropped,
                  overlapDigests.allSatisfy({ $0.digest.count == 32 && $0.retained >= minimum && $0.retained < baselineCount && baselineCount - $0.retained <= WabiHistoryWindow.maximumDropped }) else {
                throw DesktopAppError.unavailable("Wabi's saved chat could not be verified.")
            }
        }
        if let messageDigests {
            guard messageDigests.count == baselineCount, messageDigests.count <= 512,
                  messageDigests.allSatisfy({ $0.count == 32 }) else {
                throw DesktopAppError.unavailable("Wabi's saved chat could not be verified.")
            }
        }
        if let canonicalBaselineDigest, canonicalBaselineDigest.count != 32 { throw DesktopAppError.unavailable("Wabi's saved chat could not be verified.") }
        if let canonicalReversedBaselineDigest, canonicalReversedBaselineDigest.count != 32 { throw DesktopAppError.unavailable("Wabi's saved chat could not be verified.") }
        if let canonicalMessageDigests, canonicalMessageDigests.count != baselineCount || canonicalMessageDigests.count > 512 || canonicalMessageDigests.contains(where: { $0.count != 32 }) {
            throw DesktopAppError.unavailable("Wabi's saved chat could not be verified.")
        }
        if let canonicalOverlapDigests {
            let minimum = WabiHistoryWindow.minimumRetained(baselineCount)
            guard canonicalOverlapDigests.count <= 2 * WabiHistoryWindow.maximumDropped,
                  canonicalOverlapDigests.allSatisfy({ $0.digest.count == 32 && $0.retained >= minimum && $0.retained < baselineCount && baselineCount - $0.retained <= WabiHistoryWindow.maximumDropped }) else {
                throw DesktopAppError.unavailable("Wabi's saved chat could not be verified.")
            }
        }
        var answers: Set<String> = []
        var waiting = false
        if let knownHistory {
            var candidates: [[WabiAppMessage]] = []
            if knownHistory.count >= baselineCount { candidates.append(Array(knownHistory.suffix(baselineCount))) }
            if baselineCount > 0, knownHistory.count >= baselineCount - 1 {
                let greeting = WabiAppMessage(role: .assistant, text: "What can I do for you?")
                candidates.append([greeting] + Array(knownHistory.suffix(baselineCount - 1)))
            }
            for history in candidates {
                let hash = try Self.digest(history)
                if hash == baselineDigest || hash == reversedBaselineDigest {
                    return try WabiAppReceipt(baseline: history, prompt: prompt).reply(in: messages)
                }
            }
        }
        for ordered in [messages, Array(messages.reversed())] {
            let minimumCandidate = max(0, ordered.count - 2)
            let maximumCandidate = min(baselineCount, ordered.count)
            guard minimumCandidate <= maximumCandidate else { continue }
            for retained in minimumCandidate...maximumCandidate {
                let old = Array(ordered.prefix(retained))
                let hash = try Self.digest(old)
                let canonicalOld = WabiHistoryWindow.canonical(old)
                let canonicalHash = try Self.digest(canonicalOld)
                let fullMatch = retained == baselineCount && (hash == baselineDigest || hash == reversedBaselineDigest || canonicalHash == canonicalBaselineDigest || canonicalHash == canonicalReversedBaselineDigest)
                var greetingMatch = false
                if retained >= 2, retained == baselineCount - 1 {
                    let restored = [WabiAppMessage(role: .assistant, text: "What can I do for you?")] + old
                    let restoredHash = try Self.digest(restored)
                    let restoredCanonical = try Self.digest(WabiHistoryWindow.canonical(restored))
                    greetingMatch = restoredHash == baselineDigest || restoredHash == reversedBaselineDigest ||
                        restoredCanonical == canonicalBaselineDigest || restoredCanonical == canonicalReversedBaselineDigest
                }
                let minimum = WabiHistoryWindow.minimumRetained(baselineCount)
                let overlapMatch = retained >= minimum && retained < baselineCount && baselineCount - retained <= WabiHistoryWindow.maximumDropped &&
                    ((overlapDigests?.contains { $0.retained == retained && $0.digest == hash } ?? false) || (canonicalOverlapDigests?.contains { $0.retained == retained && $0.digest == canonicalHash } ?? false))
                let rowMatch: Bool
                if let messageDigests {
                    let observed = try old.map { try Self.digest([$0]) }
                    let rawRowMatch = [messageDigests, Array(messageDigests.reversed())].contains {
                        WabiHistoryWindow.matchesMissingOlderRow(baseline: $0, observed: observed)
                    }
                    let canonicalRowMatch = try canonicalMessageDigests.map { digests in
                        let observed = try canonicalOld.map { try Self.digest([$0]) }
                        return [digests, Array(digests.reversed())].contains { WabiHistoryWindow.matchesMissingOlderRow(baseline: $0, observed: observed) }
                    } ?? false
                    rowMatch = rawRowMatch || canonicalRowMatch
                } else { rowMatch = false }
                guard fullMatch || greetingMatch || overlapMatch || rowMatch else { continue }
                let added = ordered.dropFirst(retained)
                if added.isEmpty { waiting = true; continue }
                guard let outgoing = added.first, outgoing.role == .user,
                      outgoing.text.split(whereSeparator: \.isWhitespace) == prompt.split(whereSeparator: \.isWhitespace) else { continue }
                if added.count == 1 { waiting = true }
                else if let answer = added.last, answer.role == .assistant, !answer.text.isEmpty { answers.insert(answer.presentation ?? answer.text) }
            }
        }
        guard answers.count <= 1 else { throw DesktopAppError.unavailable("Wabi's new reply is ambiguous.") }
        if let answer = answers.first { return answer }
        if waiting { return nil }
        throw DesktopAppError.unavailable("Wabi's chat changed. No reply was attributed.")
    }
}

enum WabiAppProfile {
    static func isNewChatChooser(_ state: DesktopAppSnapshot) -> Bool {
        let fields = state.body.filter { $0.role == "AXTextField" && $0.label == "Name, username, or phone number" }
        return fields.count == 1 && ["", "Name, username, or phone number"].contains(fields[0].value ?? "") &&
            state.body.first(where: { $0.role == "AXHeading" })?.label == "New chat"
    }
    static func newAIChatChoice(_ state: DesktopAppSnapshot) throws -> DesktopAppSnapshot.Element {
        guard isNewChatChooser(state) else { throw DesktopAppError.unavailable("Wabi's New chat chooser changed. Nothing was selected.") }
        let lists = Set(state.body.filter { $0.role == "AXList" }.compactMap(\.element_index))
        let choices = state.body.filter { $0.role == "AXButton" && $0.label == "New chat" && $0.enabled != false && $0.element_token != nil && $0.parent_index.map(lists.contains) == true }
        guard choices.count == 1 else { throw DesktopAppError.unavailable("Wabi's AI chat choice is unavailable or ambiguous. Nothing was selected.") }
        return choices[0]
    }
    static func capture(_ target: DesktopAppConversation.Target, purpose: WabiReadPurpose = .conversation) throws -> WabiAppObservation {
        do { return try parse(DesktopAccessibility.capture(target, app: .wabi), purpose: purpose) }
        catch DesktopAccessibilityError.incomplete { throw WabiObservationError.transient("Wabi's controls are still updating.") }
    }
    static func parse(_ root: DesktopAccessibilityNode, purpose: WabiReadPurpose = .conversation) throws -> WabiAppObservation {
        let nodes = root.descendants
        guard !nodes.contains(where: { ["AXSheet", "AXDialog"].contains($0.role) }) else { throw DesktopAppError.unavailable("Dismiss Wabi's dialog before continuing.") }
        let areas = nodes.filter { $0.role == "AXWebArea" }
        let composers = nodes.filter { DesktopAccessibility.isComposer($0, app: .wabi) }
        let url = try WabiThread.verifiedURL(areas.first?.url, currentURL: areas.first?.url, webAreaCount: areas.count, composerCount: composers.count, purpose: purpose)
        if let composer = composers.first, composer.value == nil { throw DesktopAppError.unavailable("Wabi's draft is unreadable. It was preserved.") }
        func convert(_ node: DesktopAccessibilityNode) -> WabiAXNode {
            .init(role: node.role, label: node.label, value: node.value ?? "", classes: node.classes, children: node.children.map(convert))
        }
        let links = nodes.filter { $0.role == "AXLink" }.compactMap { node in node.url.map { WabiAppObservation.Link(label: node.label, url: $0) } }
        return .init(url: url, draft: composers.first?.value, links: links,
                     messages: try WabiNativeMessages.read(convert(root), purpose: purpose), composerFocused: composers.first?.focused ?? false)
    }
}

actor WabiAppConversation {
    static let shared = WabiAppConversation()
    typealias NativeRead = @Sendable (DesktopAppConversation.Target, WabiReadPurpose) throws -> WabiAppObservation
    private let driver: DesktopAppConversation
    private let timing: DesktopAppConversation.Timing
    private let readNative: NativeRead
    private var occupied = false
    init(executable: URL? = nil, timing: DesktopAppConversation.Timing = .init(), readNative: @escaping NativeRead = { try WabiAppProfile.capture($0, purpose: $1) }) {
        driver = DesktopAppConversation(executable: executable, timing: timing)
        self.timing = timing; self.readNative = readNative
    }
    private func native(_ target: DesktopAppConversation.Target, purpose: WabiReadPurpose = .conversation) async throws -> WabiAppObservation {
        let read = readNative
        var retries = 2
        let readinessDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while true {
            try Task.checkCancellation()
            do { return try await Task.detached { try read(target, purpose) }.value }
            catch WabiObservationError.transient where purpose == .readiness ? ContinuousClock.now < readinessDeadline : retries > 0 {
                retries -= 1
                try await Task.sleep(for: timing.pollInterval)
            }
        }
    }
    private func observe(_ target: DesktopAppConversation.Target, session: String, screenshotURL: URL? = nil, purpose: WabiReadPurpose = .conversation) async throws -> (DesktopAppSnapshot, WabiAppObservation) {
        try Task.checkCancellation()
        // A cold Electron window can expose no web content until Cua enables
        // its accessibility tree. Initialize it before waiting for the native URL.
        let readinessState = purpose == .readiness ? try await driver.snapshot(target, session: session, screenshotURL: screenshotURL) : nil
        try readinessState?.checkReadable()
        let before = try await native(target, purpose: purpose)
        let state: DesktopAppSnapshot
        if let readinessState { state = readinessState }
        else { state = try await driver.snapshot(target, session: session, screenshotURL: screenshotURL) }
        try state.checkReadable()
        let after = try await native(target, purpose: purpose)
        guard before.url == after.url, before.draft == after.draft,
              screenshotURL == nil || (before.messages == after.messages && before.composerFocused == after.composerFocused) else { throw DesktopAppError.unavailable("Wabi changed while checking its chat. Nothing was retried.") }
        return (state, after)
    }
    private func driverDraftAgrees(_ composer: (element: DesktopAppSnapshot.Element, draft: String), with exact: String) -> Bool {
        // Structured values can trim whitespace or echo the empty editor's
        // placeholder. The independent native draft must still match exactly.
        let value = composer.element.value ?? ""
        let trimmed = exact.trimmingCharacters(in: .whitespacesAndNewlines)
        return value == exact || value == trimmed || (trimmed.isEmpty && composer.draft.isEmpty)
    }
    private func empty(_ state: DesktopAppSnapshot, _ native: WabiAppObservation) throws {
        guard native.draft == "", try state.composer(app: .wabi).draft.isEmpty, !state.isGenerating else {
            throw DesktopAppError.unavailable("Wabi has an unsent draft or an active response. It was preserved.")
        }
    }
    private func button(_ state: DesktopAppSnapshot, _ label: String) throws -> DesktopAppSnapshot.Element {
        let matches = state.body.filter { $0.role == "AXButton" && $0.label == label && $0.enabled != false && $0.element_token != nil }
        guard matches.count == 1 else { throw DesktopAppError.unavailable("Wabi's \(label) control is unavailable or ambiguous.") }
        return matches[0]
    }
    private func click(_ element: DesktopAppSnapshot.Element, _ target: DesktopAppConversation.Target, session: String) async throws {
        _ = try await driver.call("click", ["element_token": element.element_token!, "session": session, "delivery_mode": "background"], numbers: ["pid": target.pid, "window_id": target.window], as: DesktopAppConversation.Action.self)
    }
    private func settled(_ target: DesktopAppConversation.Target, session: String, purpose: WabiReadPurpose = .conversation,
                         refreshNavigation: (@Sendable (DesktopAppConversation.Target, String) async throws -> Void)? = nil,
                         canRefresh: (DesktopAppSnapshot, WabiAppObservation) -> Bool = { _, _ in false },
                         expected: (DesktopAppSnapshot, WabiAppObservation) throws -> Bool) async throws -> (DesktopAppSnapshot, WabiAppObservation) {
        var refreshRequested = false
        var refreshed = false
        return try await DesktopAppWorkflow.wait(timeout: .seconds(8), interval: timing.pollInterval,
            failure: "Wabi did not open the expected chat. Nothing was sent or retried.",
            read: {
                if refreshRequested && !refreshed, let refreshNavigation {
                    refreshed = true
                    try await refreshNavigation(target, session)
                }
                return try await self.observe(target, session: session, purpose: purpose)
            }, ready: { observation in
                let (state, native) = observation
                let ready = try expected(state, native)
                if !ready && !refreshed && canRefresh(state, native) { refreshRequested = true }
                return ready
            })
    }

    func checkAvailable() async throws {
        guard !occupied else { throw DesktopAppError.unavailable("Wabi is already handling a request.") }
        occupied = true
        defer { occupied = false }
        let session = "msgblast-wabi-check-\(UUID())"
        defer { Task { await driver.endSession(session) } }
        let target = try await driver.target(.wabi)
        // Connecting proves readiness to create a dedicated chat, not the
        // readability of unrelated messages in the currently open chat.
        let (state, native) = try await observe(target, session: session, purpose: .readiness)
        if WabiAppProfile.isNewChatChooser(state), (native.draft == nil || native.draft == ""), !state.isGenerating {
            _ = try WabiAppProfile.newAIChatChoice(state)
            return
        }
        try empty(state, native)
        _ = try button(state, "New chat")
    }
    func prepare(savedURL: URL?, refreshNavigation: (@Sendable (DesktopAppConversation.Target, String) async throws -> Void)? = nil) async throws -> URL {
        guard !occupied else { throw DesktopAppError.unavailable("Wabi is already handling a request.") }
        occupied = true
        defer { occupied = false }
        let session = "msgblast-wabi-prepare-\(UUID())"
        defer { Task { await driver.endSession(session) } }
        let target = try await driver.target(.wabi)
        var (state, native) = try await observe(target, session: session, purpose: .readiness)
        let openChooser = savedURL == nil && (native.draft == nil || native.draft == "") &&
            !state.isGenerating && WabiAppProfile.isNewChatChooser(state)
        if !openChooser { try empty(state, native) }
        if let savedURL {
            guard WabiThread.isValid(savedURL) else { throw DesktopAppError.unavailable("The saved Wabi chat address is invalid. No replacement was created.") }
            if native.url == savedURL { return savedURL }
            let original = native.url
            let links = native.links.filter { $0.url == savedURL }
            guard links.count == 1 else { throw DesktopAppError.unavailable("Open this comparison's saved chat in Wabi and try again. No replacement chat was created.") }
            let matches = state.body.filter { $0.role == "AXLink" && $0.label == links[0].label && $0.enabled != false && $0.element_token != nil }
            guard matches.count == 1 else { throw DesktopAppError.unavailable("The saved Wabi chat's sidebar entry is ambiguous. Open it in Wabi and try again.") }
            try await click(matches[0], target, session: session)
            (state, native) = try await settled(target, session: session, refreshNavigation: refreshNavigation,
                canRefresh: { state, native in native.url == original && native.draft == "" && !state.isGenerating }) { _, native in native.url == savedURL && native.draft != nil }
            try empty(state, native)
            guard native.url == savedURL else { throw DesktopAppError.unavailable("Wabi did not open the saved chat. No message was sent or replacement created.") }
            return savedURL
        }
        let original = native.url
        let existing = Set(native.links.map(\.url))
        if !openChooser {
            try await click(button(state, "New chat"), target, session: session)
            (state, native) = try await settled(target, session: session, purpose: .readiness, refreshNavigation: refreshNavigation,
                canRefresh: { state, native in native.url == original && (native.draft == nil || native.draft == "") && !state.isGenerating }) { state, native in
                (native.draft == nil || native.draft == "") && WabiAppProfile.isNewChatChooser(state)
            }
        }
        guard native.url == original, native.draft == nil || native.draft == "", WabiAppProfile.isNewChatChooser(state) else {
            throw DesktopAppError.unavailable("Wabi did not open its New chat chooser. Nothing was sent.")
        }
        try await click(WabiAppProfile.newAIChatChoice(state), target, session: session)
        (state, native) = try await settled(target, session: session, refreshNavigation: refreshNavigation,
            canRefresh: { state, native in native.url == original && (native.draft == nil || native.draft == "") && WabiAppProfile.isNewChatChooser(state) && !state.isGenerating }) { _, native in native.url != original && native.draft != nil }
        try empty(state, native)
        guard native.url != original, !existing.contains(native.url),
              state.body.filter({ $0.role == "AXHeading" }).compactMap(\.label) == ["New chat"],
              native.messages == [.init(role: .assistant, text: "What can I do for you?")] else { throw DesktopAppError.unavailable("Wabi's new AI chat could not be confirmed. Nothing was sent.") }
        return native.url
    }
    func reply(_ prompt: String, in url: URL, onSubmitAction: @Sendable () async -> Void = {},
               onSubmitted: @Sendable () async throws -> Void = {},
               onReceipt: @Sendable ([WabiAppMessage]) async throws -> Void = { _ in },
               refreshInput: (@Sendable (DesktopAppConversation.Target, String) async throws -> Void)? = nil,
               releaseFocus: @Sendable () async throws -> Void = {}) async throws -> String {
        guard !occupied else { throw DesktopAppError.unavailable("Wabi is already handling a request.") }
        occupied = true
        defer { occupied = false }
        guard WabiThread.isValid(url), !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DesktopAppError.unavailable("Prepare this comparison's dedicated Wabi chat first.") }
        guard !prompt.unicodeScalars.contains(where: { ($0.value < 0x20 && $0.value != 0x0a) || $0.value == 0x7f }) else {
            throw DesktopAppError.unavailable("Wabi cannot safely type control characters such as tabs. Replace them with spaces; your prompt was preserved.")
        }
        let session = "msgblast-wabi-send-\(UUID())"
        defer { Task { await driver.endSession(session) } }
        let target = try await driver.target(.wabi)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("msgblast-wabi-input-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appendingPathComponent("window.png")
        var (state, native) = try await observe(target, session: session, screenshotURL: image)
        guard native.url == url else { throw DesktopAppError.unavailable("Wabi's selected chat changed. Nothing was sent.") }
        try empty(state, native)
        let receipt = WabiAppReceipt(baseline: native.messages, prompt: prompt)
        try await onReceipt(native.messages)
        var point = (x: 0, y: 0)
        try await DesktopAppWorkflow.enterText(prompt, before: { step in
            if !step.first { (state, native) = try await self.observe(target, session: session, screenshotURL: image) }
            let field = try state.composer(app: .wabi)
            guard native.url == url, native.draft == step.before, self.driverDraftAgrees(field, with: step.before),
                  receipt.unchanged(native.messages), !state.isGenerating,
                  step.before.isEmpty || native.composerFocused == true else {
                throw DesktopAppError.unavailable("Wabi's draft, focus, or chat changed. Send was not pressed; review the preserved text.")
            }
            point = try state.pixelCenter(of: field.element, target: target, imageURL: image, appName: "Wabi")
        }, perform: { step in
            if step.input == .newline, native.composerFocused != true {
                _ = try await self.driver.call("click", ["session": session, "delivery_mode": "background"], numbers: ["pid": target.pid, "window_id": target.window, "x": point.x, "y": point.y], as: DesktopAppConversation.Action.self)
                let (focusedState, focused) = try await self.observe(target, session: session)
                guard focused.url == url, focused.draft == step.before, try self.driverDraftAgrees(focusedState.composer(app: .wabi), with: step.before),
                      focused.composerFocused == true, receipt.unchanged(focused.messages), !focusedState.isGenerating else {
                    throw DesktopAppError.unavailable("Wabi did not retain focus in its empty composer. Nothing was submitted.")
                }
            }
            try await self.driver.input(step.input, focus: step.before.isEmpty, point: point, target: target, session: session)
        }, after: { step in
            (state, native) = try await self.observe(target, session: session)
            let field = try state.composer(app: .wabi)
            let nativeExpected = native.draft == step.after
            let driverExpected = self.driverDraftAgrees(field, with: step.after)
            // A previously submitted input may remain invisible to Electron's
            // accessibility tree until its already-owned window is activated.
            // Refresh once only when both reads still show the old or expected
            // prefix and the owned chat and history have not changed.
            if (!nativeExpected || !driverExpected || native.composerFocused != true), let refreshInput,
               native.url == url, (nativeExpected || native.draft == step.before),
               (driverExpected || self.driverDraftAgrees(field, with: step.before)),
               receipt.unchanged(native.messages), !state.isGenerating {
                try await refreshInput(target, session)
                (state, native) = try await self.observe(target, session: session)
            }
            guard native.url == url, native.draft == step.after, try self.driverDraftAgrees(state.composer(app: .wabi), with: step.after),
                  native.composerFocused == true, receipt.unchanged(native.messages), !state.isGenerating else {
                throw DesktopAppError.unavailable("Wabi's prepared draft, focus, or chat changed. Send was not pressed; review the preserved text.")
            }
        })
        var submissionObserved = false
        return try await DesktopAppWorkflow.reply(app: "Wabi", timing: timing, onSubmitAction: onSubmitAction, releaseFocus: releaseFocus, submit: {
            try await self.click(state.sendButton(app: .wabi), target, session: session)
        }, observe: {
            (state, native) = try await self.observe(target, session: session, purpose: .sentWaiting)
            guard native.url == url else { throw DesktopAppError.unavailable("Wabi switched chats while waiting. No automatic resend.") }
            let answer = try receipt.reply(in: native.messages)
            if native.draft == "", !receipt.unchanged(native.messages), !submissionObserved {
                submissionObserved = true
                try await onSubmitted()
                try await releaseFocus()
            }
            return native.draft == "" && !state.isGenerating ? answer : nil
        })
    }

    /// Read only the currently open, already-owned thread; never navigate or resend.
    func recoverReply(_ receipt: WabiReplyReceipt, knownHistory: [WabiAppMessage]? = nil) async throws -> String? {
        guard !occupied else { return nil }
        guard receipt.version == 1, WabiThread.isValid(receipt.url) else {
            throw DesktopAppError.unavailable("Wabi's saved chat could not be verified.")
        }
        occupied = true; defer { occupied = false }
        let session = "msgblast-wabi-recovery-\(UUID())"
        defer { Task { await driver.endSession(session) } }
        let target = try await driver.target(.wabi)
        func answer() async throws -> String? {
            let (state, native) = try await observe(target, session: session)
            guard native.url == receipt.url else { throw DesktopAppError.unavailable("Wabi's selected chat changed. No reply was attributed.") }
            guard !state.isGenerating else { return nil }
            return try receipt.reply(in: native.messages, knownHistory: knownHistory)
        }
        guard let first = try await answer() else { return nil }
        if timing.stableDuration > .zero { try await timing.replyClock.sleep(for: timing.stableDuration) }
        return try await answer() == first ? first : nil
    }
}
