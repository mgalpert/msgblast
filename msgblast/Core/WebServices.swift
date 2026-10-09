import Foundation
import CryptoKit

public enum WebSendStatus: String, Codable, Sendable {
    case preparing, attempting, waiting, observed, notSent, uncertain, dismissed
    public var isUnresolved: Bool { [.attempting, .waiting, .uncertain].contains(self) }
    public var confirmsSubmission: Bool { self == .observed || self == .waiting }
    public func showsAttemptBanner(for provider: WebProvider) -> Bool {
        // Web receipt attribution can fail even when the page has replied.
        // Keep uncertainty for resend protection, without presenting it as a chat error.
        self != .observed && (self != .uncertain || provider.usesNativeConversation)
    }
    public func label(for provider: WebProvider) -> String {
        switch self {
        case .preparing: "Checking \(provider.name)…"
        case .attempting: "Submitting to \(provider.name)…"
        case .waiting: "Waiting for \(provider.name)’s reply…"
        case .observed: provider.usesNativeConversation ? "\(provider.name) replied" : "Appeared in \(provider.name)"
        case .notSent: provider.usesNativeConversation ? "No completed reply from \(provider.name)" : "Not sent to \(provider.name)"
        case .uncertain: "\(provider.name) submission unconfirmed"
        case .dismissed: "Incomplete request acknowledged"
        }
    }
}

public struct WebSendAttempt: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var created = Date()
    public var text: String
    public var status: WebSendStatus
    public var detail: String?
    public var messageID: String?
    public var comparisonID: UUID?
    public var conversationURL: URL?
    public var callbackHash: Data?
    // A safely observed chat identity survives invalidation of automatic receipt attribution.
    var recoveryConversationURL: URL?
    var receiptContext: WebReceiptContext?
    // Preparation can succeed before automatic Send is rejected. A later page
    // submission is observed separately; it is never an automatic-send receipt.
    var manualContext: WebReceiptContext?
    var pinnedConversationURL: URL? { recoveryConversationURL ?? receiptContext?.candidateURL }
    public init(text: String, status: WebSendStatus = .preparing) {
        self.text = text; self.status = status
    }
}

struct WebReceiptContext: Codable, Equatable, Sendable {
    var originalURL: URL
    var baseline: [WebPageMessage]
    var existingPaths: Set<String>
    var candidateURL: URL?
}

public struct WebWorkspaceState: Codable, Sendable {
    public var providerIdentityVersion = 2
    public var enabled: Bool?
    public var dotsURL: URL?
    public var savedAvatar: Data?
    public var grokBotRememberedConnection: Bool?
    var legacyLocalStatePresent = false
    public var sessionID = UUID()
    public var draft = ""
    public var selected = true
    public var messageRecipients: Set<UUID> = []
    public var comparisonID: UUID?
    public var attempts: [WebSendAttempt] = []
    public var conversationURLs: [String: URL] = [:]
    public var webDrafts: [String: String] = [:]
    public var localConversations: [String: [WebPageMessage]] = [:]
    public var localSessionIDs: [String: String] = [:]
    // Mark the exact session created with configured tools. Old IDs stay available
    // for recovery when a restricted session is replaced from its saved transcript.
    public var localSessionPolicyVersions: [String: Int] = [:]
    public var localConfiguredSessionIDs: [String: String] = [:]
    public var localPreviousSessionIDs: [String: [String]] = [:]
    public var localDrafts: [String: String] = [:]
    public init() {}
    private enum CodingKeys: String, CodingKey { case providerIdentityVersion, enabled, dotsURL, savedAvatar, grokBotRememberedConnection, sessionID, draft, selected, includeMuse, messageRecipients, comparisonID, attempts, conversationURLs, webDrafts, museConversations, localConversations, localSessionIDs, localDrafts, localConfiguredSessionIDs, localPreviousSessionIDs, localSessionPolicyVersions }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        providerIdentityVersion = try c.decodeIfPresent(Int.self, forKey: .providerIdentityVersion) ?? 1
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled)
        dotsURL = try c.decodeIfPresent(URL.self, forKey: .dotsURL)
        savedAvatar = try c.decodeIfPresent(Data.self, forKey: .savedAvatar)
        grokBotRememberedConnection = try c.decodeIfPresent(Bool.self, forKey: .grokBotRememberedConnection)
        legacyLocalStatePresent = c.contains(.localConversations) || c.contains(.localSessionIDs) || c.contains(.localDrafts)
        sessionID = try c.decode(UUID.self, forKey: .sessionID)
        draft = try c.decodeIfPresent(String.self, forKey: .draft) ?? ""
        selected = try c.decodeIfPresent(Bool.self, forKey: .selected) ?? c.decodeIfPresent(Bool.self, forKey: .includeMuse) ?? true
        messageRecipients = try c.decodeIfPresent(Set<UUID>.self, forKey: .messageRecipients) ?? []
        comparisonID = try c.decodeIfPresent(UUID.self, forKey: .comparisonID)
        conversationURLs = try c.decodeIfPresent([String: URL].self, forKey: .conversationURLs)
            ?? c.decodeIfPresent([String: URL].self, forKey: .museConversations) ?? [:]
        webDrafts = try c.decodeIfPresent([String: String].self, forKey: .webDrafts) ?? [:]
        localConversations = try c.decodeIfPresent([String: [WebPageMessage]].self, forKey: .localConversations) ?? [:]
        localSessionIDs = try c.decodeIfPresent([String: String].self, forKey: .localSessionIDs) ?? [:]
        localSessionPolicyVersions = try c.decodeIfPresent([String: Int].self, forKey: .localSessionPolicyVersions) ?? [:]
        localConfiguredSessionIDs = try c.decodeIfPresent([String: String].self, forKey: .localConfiguredSessionIDs) ?? [:]
        localPreviousSessionIDs = try c.decodeIfPresent([String: [String]].self, forKey: .localPreviousSessionIDs) ?? [:]
        localDrafts = try c.decodeIfPresent([String: String].self, forKey: .localDrafts) ?? [:]
        attempts = try c.decodeIfPresent([WebSendAttempt].self, forKey: .attempts) ?? []
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(providerIdentityVersion, forKey: .providerIdentityVersion)
        try c.encodeIfPresent(enabled, forKey: .enabled)
        try c.encodeIfPresent(dotsURL, forKey: .dotsURL)
        try c.encodeIfPresent(savedAvatar, forKey: .savedAvatar)
        try c.encodeIfPresent(grokBotRememberedConnection, forKey: .grokBotRememberedConnection)
        try c.encode(sessionID, forKey: .sessionID)
        try c.encode(draft, forKey: .draft)
        try c.encode(selected, forKey: .selected)
        try c.encode(messageRecipients, forKey: .messageRecipients)
        try c.encodeIfPresent(comparisonID, forKey: .comparisonID)
        try c.encode(attempts, forKey: .attempts)
        try c.encode(conversationURLs, forKey: .conversationURLs)
        try c.encode(webDrafts, forKey: .webDrafts)
        try c.encode(localConversations, forKey: .localConversations)
        try c.encode(localSessionIDs, forKey: .localSessionIDs)
        try c.encode(localDrafts, forKey: .localDrafts)
        try c.encode(localSessionPolicyVersions, forKey: .localSessionPolicyVersions)
        try c.encode(localConfiguredSessionIDs, forKey: .localConfiguredSessionIDs)
        try c.encode(localPreviousSessionIDs, forKey: .localPreviousSessionIDs)
    }
    public func resumableLocalSessionID(for comparison: UUID) -> String? {
        let key = comparison.uuidString
        guard let id = localSessionIDs[key], localConfiguredSessionIDs[key] == id, localSessionPolicyVersions[key] == 1 else { return nil }
        return id
    }
    public mutating func recordLocalSession(_ id: String, for comparison: UUID) {
        let key = comparison.uuidString
        if let previous = localSessionIDs[key], previous != id {
            var retained = localPreviousSessionIDs[key] ?? []
            if !retained.contains(previous) { retained.append(previous) }
            localPreviousSessionIDs[key] = retained
        }
        localSessionIDs[key] = id
        localConfiguredSessionIDs[key] = id
        localSessionPolicyVersions[key] = 1
    }
    public func hasUnresolvedSend(_ text: String) -> Bool {
        attempts.contains { $0.text == text && $0.status.isUnresolved }
    }
    public func recoveringInFlight() -> Self {
        var result = self
        for i in result.attempts.indices {
            switch result.attempts[i].status {
            case .attempting:
                result.attempts[i].status = .uncertain
                result.attempts[i].detail = "MsgBlast stopped during submission. Check the embedded chat before sending this text again."
            case .preparing:
                result.attempts[i].status = .notSent
                result.attempts[i].detail = "MsgBlast stopped before clicking Send. Any prepared text remains in the embedded chat."
            default: break
            }
        }
        return result
    }
}

public struct WebPageMessage: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var role: String
    public var text: String
    public init(id: String = UUID().uuidString, role: String, text: String) {
        self.id = id; self.role = role; self.text = text
    }
}

public struct WebPageSnapshot: Decodable, Equatable, Sendable {
    public var url = ""
    public var ready = false
    // Unknown while loading or when the account markup cannot be recognized.
    public var signedIn: Bool?
    public var reason = "Open this agent to sign in here."
    public var draft = ""
    public var draftAvailable: Bool?
    public var hasDraft: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var messages: [WebPageMessage] = []
    public var submissionInterrupted: Bool?
    public var signedOut: Bool?
    public init() {}
}

public struct AgentBroadcastResult: Sendable {
    public let web: [WebProvider: WebSendAttempt]
    public let comparisonID: UUID?
}

@MainActor
public enum AgentBroadcast {
    public static func send(
        draft: String,
        currentDraft: @MainActor () -> String,
        clearDraft: @MainActor () -> Void,
        web: @MainActor @Sendable (String) async -> [WebProvider: WebSendAttempt],
        messages: @MainActor @Sendable (String) async -> UUID?
    ) async -> AgentBroadcastResult {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        async let webAttempts = web(text)
        async let comparisonID = messages(text)
        let result = await AgentBroadcastResult(web: webAttempts, comparisonID: comparisonID)
        let mayHaveSent = result.comparisonID != nil || result.web.values.contains { [.observed, .waiting, .uncertain].contains($0.status) }
        // Keep edits to the next message; a wholly rejected broadcast remains ready to correct.
        if mayHaveSent && currentDraft() == draft { clearDraft() }
        return result
    }
}

/// Splits the legacy shared web/CLI storage format without moving WebKit stores
/// or CLI working directories. Each original file remains available as a backup.
public enum WebProviderStateMigration {
    public static let pairs: [(web: WebProvider, native: WebProvider)] = [(.chatgpt, .codexCLI), (.claude, .claudeCode)]

    public static func migrate(web: WebProvider, native: WebProvider, directory: URL) throws {
        let source = directory.appendingPathComponent(web.storageFilename)
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        let bytes = try Data(contentsOf: source)
        var browser = try JSONDecoder().decode(WebWorkspaceState.self, from: bytes)
        guard browser.providerIdentityVersion < 2 else { return }
        let destination = directory.appendingPathComponent(native.storageFilename)
        func hasNativeHistory(_ attempt: WebSendAttempt) -> Bool {
            guard let key = attempt.comparisonID?.uuidString else { return false }
            return browser.localConversations[key]?.isEmpty == false || browser.localSessionIDs[key] != nil || browser.localDrafts[key]?.isEmpty == false
        }
        let nativeAttempts = browser.legacyLocalStatePresent ? browser.attempts.filter { $0.conversationURL == nil } : []
        // Empty local keys were written even for web history. Without positive
        // provenance, retain the original receipt and its resend guard in both stores.
        let ambiguousAttempts = Set(nativeAttempts.filter { $0.status != .observed || !hasNativeHistory($0) }.map(\.id))
        let hasNativeState = browser.legacyLocalStatePresent && (!browser.localConversations.isEmpty || !browser.localSessionIDs.isEmpty || browser.localDrafts.values.contains { !$0.isEmpty } || !nativeAttempts.isEmpty || !browser.draft.isEmpty)
        if hasNativeState {
            var local = WebWorkspaceState()
            local.selected = false
            local.enabled = false
            if FileManager.default.fileExists(atPath: destination.path) {
                // A prior launch can stop after writing the destination. Decode and
                // merge it before touching the source; malformed/conflicting data stays put.
                local = try JSONDecoder().decode(WebWorkspaceState.self, from: Data(contentsOf: destination))
            }
            local.localConversations = try merge(local.localConversations, browser.localConversations)
            local.localSessionIDs = try merge(local.localSessionIDs, browser.localSessionIDs)
            local.localSessionPolicyVersions = try merge(local.localSessionPolicyVersions, browser.localSessionPolicyVersions)
            local.localConfiguredSessionIDs = try merge(local.localConfiguredSessionIDs, browser.localConfiguredSessionIDs)
            local.localPreviousSessionIDs = try merge(local.localPreviousSessionIDs, browser.localPreviousSessionIDs)
            local.localDrafts = try merge(local.localDrafts, browser.localDrafts)
            for attempt in nativeAttempts {
                if let existing = local.attempts.first(where: { $0.id == attempt.id }) {
                    guard existing == attempt else { throw CocoaError(.fileWriteFileExists) }
                } else { local.attempts.append(attempt) }
            }
            local.attempts.sort { $0.created > $1.created }
            if local.draft.isEmpty { local.draft = browser.draft }
            local.comparisonID = local.comparisonID ?? browser.comparisonID
            local.providerIdentityVersion = 2
            try preserveOriginal(bytes, at: source)
            try write(local, to: destination)
            browser.attempts.removeAll { attempt in !ambiguousAttempts.contains(attempt.id) && nativeAttempts.contains { $0.id == attempt.id } }
        } else {
            try preserveOriginal(bytes, at: source)
        }
        browser.localConversations = [:]
        browser.localSessionIDs = [:]
        browser.localDrafts = [:]
        browser.localConfiguredSessionIDs = [:]
        browser.localSessionPolicyVersions = [:]
        browser.localPreviousSessionIDs = [:]
        browser.providerIdentityVersion = 2
        // sessionID and conversationURLs deliberately remain the original web values.
        try write(browser, to: source)
    }

    public static func migrateComparisons(in state: inout AppState, directory: URL) throws {
        let legacyComparisons = state.comparisons.filter { ($0.webProviderIdentityVersion ?? 1) < 2 }
        guard !legacyComparisons.isEmpty else { return }
        let requiredPairs = pairs.filter { pair in legacyComparisons.contains { $0.webProviders?.contains(pair.web) == true } }
        var states: [WebProvider: WebWorkspaceState] = [:]
        var failedProviders: Set<WebProvider> = []
        for pair in requiredPairs {
            do {
                try migrate(web: pair.web, native: pair.native, directory: directory)
                var pairStates: [WebProvider: WebWorkspaceState] = [:]
                for provider in [pair.web, pair.native] {
                    let url = directory.appendingPathComponent(provider.storageFilename)
                    pairStates[provider] = FileManager.default.fileExists(atPath: url.path)
                        ? try JSONDecoder().decode(WebWorkspaceState.self, from: Data(contentsOf: url)) : WebWorkspaceState()
                }
                states.merge(pairStates) { _, saved in saved }
            } catch {
                // WebAgents reports the error on this pair. Keep its comparisons
                // eligible for retry without blocking unrelated app state.
                failedProviders.insert(pair.web)
            }
        }
        for index in state.comparisons.indices where (state.comparisons[index].webProviderIdentityVersion ?? 1) < 2 {
            guard !(state.comparisons[index].webProviders ?? []).contains(where: { failedProviders.contains($0) }) else { continue }
            let id = state.comparisons[index].id.uuidString
            if let providers = state.comparisons[index].webProviders {
                state.comparisons[index].webProviders = providers.flatMap { provider -> [WebProvider] in
                    guard let pair = pairs.first(where: { $0.web == provider }), let browser = states[provider], let local = states[pair.native] else { return [provider] }
                    let nativeHistory = local.localConversations[id] != nil || local.localSessionIDs[id] != nil || local.localDrafts[id].map { !$0.isEmpty } == true || local.attempts.contains { $0.comparisonID?.uuidString == id }
                    let webHistory = browser.conversationURLs[id] != nil || browser.attempts.contains { $0.comparisonID?.uuidString == id }
                    return nativeHistory ? (webHistory ? [provider, pair.native] : [pair.native]) : [provider]
                }
            }
            state.comparisons[index].webProviderIdentityVersion = 2
        }
    }

    public static func preserveOriginal(_ bytes: Data, at source: URL) throws {
        var backup = source.deletingPathExtension().appendingPathExtension("legacy-provider-state.json")
        if FileManager.default.fileExists(atPath: backup.path), try Data(contentsOf: backup) != bytes {
            // A restored or older app can write another legacy revision. Preserve
            // both snapshots; the digest makes repeated migration attempts idempotent.
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            backup = source.deletingPathExtension().appendingPathExtension("legacy-provider-state-\(digest).json")
        }
        if FileManager.default.fileExists(atPath: backup.path) {
            guard try Data(contentsOf: backup) == bytes else { throw CocoaError(.fileWriteFileExists) }
            return
        }
        try bytes.write(to: backup, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
    }
    private static func merge<T: Equatable>(_ destination: [String: T], _ source: [String: T]) throws -> [String: T] {
        var merged = destination
        for (key, value) in source {
            if let existing = merged[key], existing != value { throw CocoaError(.fileWriteFileExists) }
            merged[key] = value
        }
        return merged
    }
    private static func write(_ state: WebWorkspaceState, to url: URL) throws {
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
