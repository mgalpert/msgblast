import Foundation

public struct SharingPreferences: Codable, Equatable, Sendable {
    public var agentUsage = true
    public var messageCounts = true
    public var activity = true
    public var reliability = true
    public var performance = true
    public init() {}
    public var usage: Bool {
        get { agentUsage && messageCounts && activity }
        set { agentUsage = newValue; messageCounts = newValue; activity = newValue }
    }
    public var health: Bool {
        get { reliability && performance }
        set { reliability = newValue; performance = newValue }
    }
    public func allows(_ category: TelemetryCategory) -> Bool {
        switch category {
        case .agentUsage: agentUsage
        case .messageCounts: messageCounts
        case .activity: activity
        case .reliability: reliability
        case .performance: performance
        }
    }
}

/// Existence means Save choices succeeded. Draft selections are never consent.
public struct SharingConsent: Codable, Equatable, Sendable {
    public var preferences: SharingPreferences
    public var installationID: UUID?
    public var cohortStartedAt: Date?
    public var revision: UUID
    public init(preferences: SharingPreferences, previous: SharingConsent? = nil, now: Date = Date()) {
        self.preferences = preferences
        installationID = preferences.activity ? previous?.installationID ?? UUID() : nil
        cohortStartedAt = preferences.activity ? previous?.cohortStartedAt ?? now : nil
        revision = UUID()
    }
}

public enum TelemetryCategory: String, Codable, Sendable {
    case agentUsage, messageCounts, activity, reliability, performance
}

/// Closed properties prevent arbitrary strings, content, URLs or identities entering telemetry.
public struct TelemetryProperties: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case shared, `private` }
    public enum Operation: String, Codable, Sendable { case send, setup, storage }
    public enum Result: String, Codable, Sendable { case success, failure }
    public enum Duration: String, Codable, Sendable {
        case under1s = "under_1s", oneTo5s = "1_to_5s", fiveTo30s = "5_to_30s", over30s = "over_30s"
        public init(seconds: TimeInterval) {
            self = seconds < 1 ? .under1s : seconds < 5 ? .oneTo5s : seconds < 30 ? .fiveTo30s : .over30s
        }
    }
    public enum Screen: String, Codable, Sendable { case connectors, permissions, messages, agents, browserImport, providerConnection, runtimeSetup, feedback }
    public var screen: Screen?
    public var previousScreen: Screen?
    public enum BuildChannel: String, Codable, Sendable { case development, production }
    public var buildChannel: BuildChannel?
    public var counts: [String: Int]?
    public var provider: String?
    public var count: Int?
    public var kind: Kind?
    public var recipientCount: Int?
    public var operation: Operation?
    public var result: Result?
    public var duration: Duration?
    public var appVersion: String?
    public var osMajor: Int?
    public var cohortDay: Int?
    public var cohortStartedAt: String?
    public init() {}
}

public struct TelemetryEvent: Codable, Sendable {
    public enum Name: String, Codable, Sendable {
        case onboardingCompleted = "onboarding_completed", agentInventory = "agent_inventory"
        case agentAdded = "agent_added", onboardingScreenViewed = "onboarding_screen_viewed"
        case messageSubmitted = "message_submitted", appActive = "app_active", appEngaged = "app_engaged"
        case operationResult = "operation_result", operationTiming = "operation_timing"
        public var category: TelemetryCategory {
            switch self {
            case .onboardingCompleted, .appActive, .appEngaged: .activity
            case .agentInventory, .agentAdded, .onboardingScreenViewed: .agentUsage
            case .messageSubmitted: .messageCounts
            case .operationResult: .reliability
            case .operationTiming: .performance
            }
        }
    }
    public var id: UUID
    public var name: Name
    public var category: TelemetryCategory
    public var timestamp: String
    public var distinctID: UUID?
    public var properties: TelemetryProperties
    public init(name: Name, properties: TelemetryProperties, consent: SharingConsent, now: Date = Date(), id: UUID = UUID()) {
        self.id = id; self.name = name; category = name.category
        timestamp = ISO8601DateFormatter().string(from: now)
        distinctID = consent.preferences.activity ? consent.installationID : nil
        self.properties = properties
        if let start = consent.cohortStartedAt, distinctID != nil {
            self.properties.cohortDay = min(3660, max(0, Int(now.timeIntervalSince(start) / 86_400)))
            self.properties.cohortStartedAt = ISO8601DateFormatter().string(from: start)
        }
    }
}

/// Best-effort statistics. The queue is bounded, independent of chat state, and never blocks UI.
public actor TelemetryCollector {
    private struct Queue: Codable { var revision: UUID; var events: [TelemetryEvent]; var logicalIDs: [UUID]? }
    private struct Batch: Encodable { let schema = 1; let events: [TelemetryEvent] }
    private let endpoint: URL?
    private let queueURL: URL
    private var consent: SharingConsent?
    private var events: [TelemetryEvent] = []
    private var logicalIDs: [UUID] = []
    private var loop: Task<Void, Never>?
    private var upload: Task<(Data, URLResponse), Error>?
    private var failureCount = 0
    private var nextAttempt = Date.distantPast
    private let session: URLSession
    public init(endpoint: URL?, queueURL: URL, session: URLSession? = nil) {
        self.endpoint = endpoint; self.queueURL = queueURL
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10; config.timeoutIntervalForResource = 15
        config.httpCookieStorage = nil; config.urlCache = nil
        self.session = session ?? URLSession(configuration: config, delegate: NoTelemetryRedirects(), delegateQueue: nil)
    }
    public static func endpoint(bundle: Bundle = .main, demo: Bool) -> URL? {
        guard !demo, bundle.bundleIdentifier == AppBundleIdentity.production || AppBundleIdentity.isDevelopment(bundle.bundleIdentifier),
              let configured = bundle.object(forInfoDictionaryKey: "msgblastTelemetryEndpoint") as? String,
              configured == "https://msgblast.app/api/telemetry" else { return nil }
        return URL(string: configured)
    }
    public func configure(_ next: SharingConsent?) {
        upload?.cancel(); upload = nil
        let changed = consent?.revision != next?.revision
        if changed {
            events = []
            failureCount = 0; nextAttempt = .distantPast
        }
        consent = next
        if endpoint == nil || next == nil {
            events = []; logicalIDs = []; loop?.cancel(); loop = nil
            try? FileManager.default.removeItem(at: queueURL)
            return
        }
        if changed,
           let attributes = try? FileManager.default.attributesOfItem(atPath: queueURL.path),
           let size = attributes[.size] as? NSNumber, size.intValue <= 256 * 1024,
           let bytes = try? Data(contentsOf: queueURL), bytes.count <= 256 * 1024,
           let saved = try? JSONDecoder().decode(Queue.self, from: bytes) {
            if saved.revision == next?.revision {
                events = Array(saved.events.filter { next!.preferences.allows($0.category) }.suffix(200))
            }
            // Local receipt deduplication survives preference edits; old statistics do not.
            if logicalIDs.isEmpty { logicalIDs = Array((saved.logicalIDs ?? []).suffix(2000)) }
        }
        persistQueue()
        if loop == nil {
            loop = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    guard !Task.isCancelled else { return }
                    await self?.flush()
                }
            }
        }
    }
    public func record(_ event: TelemetryEvent, revision: UUID) {
        guard endpoint != nil, consent?.revision == revision,
              consent?.preferences.allows(event.category) == true else { return }
        enqueue([event])
    }
    private func enqueue(_ accepted: [TelemetryEvent]) {
        events.append(contentsOf: accepted)
        if events.count > 200 { events.removeFirst(events.count - 200) }
        // The actor persists accepted events off the main thread so short sessions survive quit.
        persistQueue()
        if events.count >= 20 { Task { await self.flush() } }
    }
    public func recordSubmission(_ submissionEvents: [TelemetryEvent], revision: UUID, logicalID: UUID) {
        guard endpoint != nil, consent?.revision == revision, !logicalIDs.contains(logicalID) else { return }
        let allowed = submissionEvents.filter { consent?.preferences.allows($0.category) == true }
        guard !allowed.isEmpty else { return }
        // Local send receipt IDs are retained only for deduplication; they never leave this queue file.
        logicalIDs = Array((logicalIDs + [logicalID]).suffix(2000))
        enqueue(allowed)
    }
    public func flush(now: Date = Date()) async {
        guard let endpoint, let consent, upload == nil else { return }
        let formatter = ISO8601DateFormatter()
        events.removeAll { event in
            guard let timestamp = formatter.date(from: event.timestamp) else { return true }
            return now.timeIntervalSince(timestamp) > 7 * 86_400 || !consent.preferences.allows(event.category)
        }
        persistQueue()
        guard !events.isEmpty, now >= nextAttempt else { return }
        let batch = Array(events.prefix(20))
        guard let body = try? JSONEncoder().encode(Batch(events: batch)), body.count <= 32 * 1024 else {
            events.removeFirst(min(20, events.count)); persistQueue(); return
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("msgblast/telemetry", forHTTPHeaderField: "User-Agent")
        let task = Task { try await session.data(for: request) }
        upload = task
        do {
            let (_, response) = try await task.value
            guard self.consent?.revision == consent.revision else { return }
            guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            if response.statusCode == 204 {
                let ids = Set(batch.map(\.id)); events.removeAll { ids.contains($0.id) }
                failureCount = 0; nextAttempt = .distantPast
            } else if [400, 413, 415].contains(response.statusCode) {
                let ids = Set(batch.map(\.id)); events.removeAll { ids.contains($0.id) }
            } else { throw URLError(.badServerResponse) }
        } catch {
            if self.consent?.revision == consent.revision {
                failureCount = min(failureCount + 1, 6)
                nextAttempt = now.addingTimeInterval(min(3600, 60 * pow(2, Double(failureCount))))
            }
        }
        if self.consent?.revision == consent.revision { upload = nil; persistQueue() }
    }
    private func persistQueue() {
        guard let consent, endpoint != nil else { return }
        guard let bytes = try? JSONEncoder().encode(Queue(revision: consent.revision, events: events, logicalIDs: logicalIDs)) else { return }
        try? bytes.write(to: queueURL, options: .atomic)
    }
}

private final class NoTelemetryRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
