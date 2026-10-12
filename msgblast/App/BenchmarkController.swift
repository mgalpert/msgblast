import AppKit
import Combine
import msgblastCore

struct BenchmarkOwnedPublication: Decodable, Identifiable { let id: String; let created_at: String; let revoked_at: String? }
struct BenchmarkOwnedRecord: Decodable, Identifiable { let id: String; let local_id: String; let status: String; let fixture: Int }
@MainActor final class BenchmarkController: ObservableObject {
    let account: BenchmarkAccountSession
    private(set) var client: BenchmarkCloudClient?
    @Published var status = "Cloud actions require a separate choice."
    @Published var error: String?
    @Published private(set) var working = false
    @Published private(set) var revision = 0
    @Published private(set) var publicationLinks: [(id: String, url: URL)] = []
    @Published private(set) var remotePublications: [BenchmarkOwnedPublication] = []
    @Published private(set) var remoteRecords: [BenchmarkOwnedRecord] = []
    @Published private(set) var contributionSummaries: [BenchmarkContributionHistoryEntry] = []
    @Published private(set) var acceptedComparisons: Int?
    @Published private(set) var contributionHistory = "No contribution history loaded."
    @Published private(set) var cloudSessions = "No private records loaded."
    private weak var performance: PerformanceController?
    private var autoTask: Task<Void, Never>?
    private var restored = false
    private var stopped = false
    private var presentationOwner: String?
    private var subscriptions = Set<AnyCancellable>()
    var lineages: [BenchmarkSyncLineage] { client?.store.lineages ?? [] }
    var paused: Bool { client?.store.paused ?? true }
    init(directory: URL, demo: Bool, bundle: Bundle = .main) {
        let config: BenchmarkAccountConfiguration?
        do {
            if !demo, let service = bundle.object(forInfoDictionaryKey: "BenchmarkServiceURL") as? String,
               let issuer = bundle.object(forInfoDictionaryKey: "BenchmarkIssuer") as? String,
               let clientID = bundle.object(forInfoDictionaryKey: "BenchmarkClientID") as? String,
               let audience = bundle.object(forInfoDictionaryKey: "BenchmarkAudience") as? String,
               let callback = bundle.object(forInfoDictionaryKey: "BenchmarkCallbackURL") as? String,
               let serviceURL = URL(string: service), let issuerURL = URL(string: issuer), let callbackURL = URL(string: callback) {
                config = try .init(serviceURL: serviceURL, issuer: issuerURL, clientID: clientID, audience: audience, callbackURL: callbackURL, bundleIdentifier: bundle.bundleIdentifier ?? "com.msgblast.mac", profile: "managed")
            } else { config = nil }
        } catch { config = nil }
        if let fixture = try? BenchmarkDemoFixture.load(demo: demo) {
            account = BenchmarkAccountSession(configuration: fixture.configuration, browser: fixture.browser, transport: fixture.transport, tokenStore: fixture.tokens)
            status = "Synthetic Demo: OAuth browser/code exchange and credential storage are simulated. Cloud operations use a loopback Worker."
        } else {
            account = BenchmarkAccountSession(configuration: config, browser: BenchmarkOAuthSystemBrowser(window: { NSApp.keyWindow ?? NSApp.mainWindow ?? NSWindow() }), transport: BenchmarkURLSessionTransport(), tokenStore: BenchmarkKeychainTokenStore())
        }
        do { client = BenchmarkCloudClient(account: account, store: try BenchmarkSyncStore(directory: directory)) }
        catch { self.error = error.localizedDescription }
        observeAccount()
    }
    init(account: BenchmarkAccountSession, store: BenchmarkSyncStore) {
        self.account = account; client = BenchmarkCloudClient(account: account, store: store)
        observeAccount()
    }
    private func clearCloudPresentation() {
        remotePublications = []; remoteRecords = []; contributionSummaries = []; publicationLinks = []
        acceptedComparisons = nil; contributionHistory = "No contribution history loaded."; cloudSessions = "No private records loaded."
    }
    private func observeAccount() {
        account.$account.sink { [weak self] identity in
            guard let self else { return }
            if self.presentationOwner != identity?.accountID {
                self.presentationOwner = identity?.accountID; self.clearCloudPresentation()
            }
            self.objectWillChange.send()
        }.store(in: &subscriptions)
        account.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
    }
    private func loadLinks() {
        publicationLinks = (client?.store.publications ?? []).filter { $0.owner == account.account?.accountID && !$0.revoked }.map { ($0.id, $0.url) }
    }
    func restore() async {
        guard !restored else { return }; restored = true
        await account.restore(); loadLinks(); scheduleFuture()
    }
    func signIn() async { clearCloudPresentation(); await account.signIn(); loadLinks(); scheduleFuture() }
    func signOut() {
        autoTask?.cancel(); autoTask = nil; client?.cancel(); do { try client?.pause() } catch { self.error = error.localizedDescription }
        acceptedComparisons = nil
        account.signOut(); remotePublications = []; remoteRecords = []; contributionSummaries = []; publicationLinks = []; contributionHistory = "Sign in to view history."; cloudSessions = "Sign in to view private records."; revision += 1
    }
    func shutdown() { stopped = true; autoTask?.cancel(); autoTask = nil; client?.cancel() }
    func clearLocalUploads() throws {
        autoTask?.cancel(); autoTask = nil
        guard let client else { throw BenchmarkSyncError.invalidJournal }
        client.cancel(); try client.store.clearLocalUploads(); revision += 1
    }
    func pause() { autoTask?.cancel(); autoTask = nil; do { try client?.pause(); revision += 1; status = "Private sync paused. Saved retries are retained for this account." } catch { self.error = error.localizedDescription } }
    var futureSync: Bool { client?.store.futureOwner == account.account?.accountID && account.account != nil }
    func attach(performance: PerformanceController) {
        self.performance = performance
        performance.$revision.dropFirst().sink { [weak self] _ in self?.scheduleFuture() }.store(in: &subscriptions)
        if client?.store.futureOwner != nil { Task { await restore() } }
    }
    func setFutureSync(_ enabled: Bool) {
        guard let client, let owner = account.account?.accountID else { return }
        do {
            if !enabled { autoTask?.cancel(); autoTask = nil; client.cancel() }
            try client.store.setFutureSync(enabled: enabled, owner: owner, events: performance?.events ?? [])
            status = enabled ? "Future recording sync enabled for this account. Existing comparisons need explicit selection; prior selected cloud lineages can continue privately." : "Future recording sync disabled. Saved owner-bound retries remain paused."
            revision += 1; scheduleFuture()
        } catch { self.error = error.localizedDescription }
    }
    private func scheduleFuture() {
        guard !stopped, autoTask == nil, !working, !account.deletionOnly, futureSync, !paused, let performance, let client, let owner = account.account?.accountID else { return }
        let counts = Dictionary(grouping: performance.events, by: \.comparisonID).mapValues(\.count)
        let lineages = Dictionary(uniqueKeysWithValues: client.store.lineages.map { ($0.comparisonID, $0) })
        let candidates = client.store.futureComparisons(events: performance.events, owner: owner).filter { id in
            let count = counts[id] ?? 0
            let lineage = lineages[id]
            return count > (lineage?.selectedSequenceEnd ?? 0) || (lineage != nil && lineage?.finalized == false)
        }
        guard !candidates.isEmpty else { return }
        let accountGeneration = account.generation
        autoTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            guard !self.working, !self.account.deletionOnly, self.account.generation == accountGeneration else { self.autoTask = nil; return }
            self.working = true
            var failed = false
            do {
                for id in client.store.futureComparisons(events: performance.events, owner: owner) {
                    let events = performance.events
                    let count = events.lazy.filter { $0.comparisonID == id }.count
                    let lineage = client.store.lineages.first { $0.comparisonID == id }
                    guard count > (lineage?.selectedSequenceEnd ?? 0) || (lineage != nil && lineage?.finalized == false) else { continue }
                    if count > (lineage?.selectedSequenceEnd ?? 0) {
                        _ = try client.store.prepare(events: events, comparisonID: id, owner: owner, context: lineage?.context ?? "unknown")
                    }
                    _ = try await client.upload(comparisonID: id, owner: owner)
                }
                self.status = "Future selected recordings synced privately. Publications and contribution selections are unchanged."
            } catch {
                if self.account.generation == accountGeneration {
                    failed = true; self.error = error.localizedDescription
                    if !BenchmarkCloudRetry.isRetryable(error) { try? client.pause() }
                }
            }
            self.working = false; self.revision += 1; self.autoTask = nil
            // Failed exact retries remain saved. The explicit Resume action or a
            // later recording retries them with bounded transport backoff.
            if failed, self.futureSync, !self.paused {
                self.autoTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    guard let self else { return }; self.autoTask = nil; self.scheduleFuture()
                }
            } else { self.scheduleFuture() }
        }
    }
    private func action(_ operation: () async throws -> Void) async {
        guard !working else { return }
        autoTask?.cancel(); autoTask = nil
        working = true; error = nil
        let expectedAccountGeneration = account.generation
        defer { working = false; revision += 1; scheduleFuture() }
        do { try await operation() } catch {
            guard account.generation == expectedAccountGeneration else { return }
            if case BenchmarkAccountError.quota = error { try? client?.pause() }
            self.error = error.localizedDescription
        }
    }
    func upload(events: [PerformanceEvent], comparisonID: String, context: String) async {
        await action {
            guard let client, let owner = account.account?.accountID else { throw BenchmarkAccountError.signedOut }
            _ = try client.store.prepare(events: events, comparisonID: comparisonID, owner: owner, context: context)
            let wasPaused = client.store.paused
            try client.resume()
            defer { if wasPaused { try? client.pause() } }
            _ = try await client.upload(comparisonID: comparisonID, owner: owner)
            status = "Selected private snapshot uploaded. Validation is pending; no contribution was requested."
        }
    }
    func resumeSaved() async {
        await action {
            guard let client, let owner = account.account?.accountID else { throw BenchmarkAccountError.signedOut }
            try client.resume()
            for lineage in client.store.lineages where lineage.owner == owner && !lineage.finalized {
                _ = try await client.upload(comparisonID: lineage.comparisonID, owner: owner)
            }
            status = "Saved selected uploads finished. No newer local events were selected."
        }
    }
    func publish(_ publication: ComparisonPublication, comparisonID: String, owner: String, accountGeneration: UInt64) async {
        await action {
            guard let client, let config = account.configuration else { throw BenchmarkAccountError.signedOut }
            try checkOwner(owner, generation: accountGeneration)
            let expected = accountGeneration
            let approvedHash = try publication.previewHash()
            let data = try await client.publish(publication, comparisonID: comparisonID, owner: owner)
            try checkOwner(owner, generation: expected)
            let result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let id = result?["id"] as? String, let path = result?["path"] as? String,
                  result?["projectionHash"] as? String == approvedHash,
                  path.hasPrefix("/s/"), let url = URL(string: path, relativeTo: config.serviceURL)?.absoluteURL else { throw BenchmarkAccountError.invalidResponse }
            try client.store.savePublication(.init(id: id, owner: owner, url: url, projectionHash: approvedHash, comparisonID: comparisonID))
            publicationLinks.append((id, url)); status = "Reviewed comparison published. Anyone with the link can read and forward it."
        }
    }
    func revoke(_ id: String) async {
        await action {
            guard let client, let owner = account.account?.accountID else { throw BenchmarkAccountError.signedOut }
            let expected = account.generation
            try await client.revoke(publicationID: id, owner: owner)
            try checkOwner(owner, generation: expected)
            try client.store.revokePublication(id, owner: owner)
            remotePublications.removeAll { $0.id == id }
            publicationLinks.removeAll { $0.id == id }; status = "Link revoked. Previously downloaded copies cannot be recalled."
        }
    }
    func prepareContribution(events: [PerformanceEvent], comparisonID: String, context: String) async {
        await action {
            guard let client, let owner = account.account?.accountID else { throw BenchmarkAccountError.signedOut }
            _ = try client.store.prepare(events: events, comparisonID: comparisonID, owner: owner, context: context, purpose: "contribution")
            _ = try await client.upload(comparisonID: comparisonID, owner: owner, contributionSelection: true)
            status = "Selected contribution evidence uploaded privately for validation. Private sync remains \(client.store.paused ? "paused" : "enabled"). Contribution still requires the separate final choice."
        }
    }
    func contribute(_ approval: BenchmarkContributionApproval) async {
        await action {
            guard let client, let owner = account.account?.accountID, owner == approval.owner else { throw BenchmarkSyncError.ownerMismatch }
            let expected = account.generation
            _ = try await client.contributeSelected(approval)
            try checkOwner(owner, generation: expected)
            status = "Contribution requested for the selected snapshot. Validation determines eligibility; this comparison counts once."
            try await loadHistory(owner: owner)
        }
    }
    func withdraw(_ lineage: BenchmarkSyncLineage) async {
        await action {
            guard let client, let owner = account.account?.accountID, owner == lineage.owner, let session = lineage.sessionID else { throw BenchmarkSyncError.ownerMismatch }
            let expected = account.generation
            try await client.withdraw(sessionID: session, owner: owner)
            try checkOwner(owner, generation: expected); status = "Contribution withdrawn."
            try await loadHistory(owner: owner)
        }
    }
    private func checkOwner(_ owner: String, generation: UInt64) throws {
        guard account.generation == generation, account.account?.accountID == owner else { throw BenchmarkSyncError.staleOperation }
    }
    private func readable(_ data: Data) throws -> String {
        let value = try JSONSerialization.jsonObject(with: data)
        let formatted = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
        return String(decoding: formatted, as: UTF8.self)
    }
    private func loadHistory(owner: String) async throws {
        guard let client else { return }
        acceptedComparisons = nil
        let expected = account.generation
        let data = try await client.list("contributions", owner: owner)
        try checkOwner(owner, generation: expected)
        struct History: Decodable { let history: [BenchmarkContributionHistoryEntry]; let acceptedDistinctSessions: Int }
        let history = try JSONDecoder().decode(History.self, from: data)
        guard history.acceptedDistinctSessions >= 0 else { throw BenchmarkAccountError.invalidResponse }
        contributionSummaries = history.history; acceptedComparisons = history.acceptedDistinctSessions
        contributionHistory = try readable(data)
    }
    func refreshRecords() async {
        await action {
            guard let client, let owner = account.account?.accountID else { throw BenchmarkAccountError.signedOut }
            acceptedComparisons = nil
            let expected = account.generation
            let records = try await client.list("sessions", owner: owner)
            let history = try await client.list("contributions", owner: owner)
            let publications = try await client.list("publications", owner: owner)
            guard account.generation == expected, account.account?.accountID == owner else { throw BenchmarkSyncError.staleOperation }
            struct History: Decodable { let history: [BenchmarkContributionHistoryEntry]; let acceptedDistinctSessions: Int }
            let contribution = try JSONDecoder().decode(History.self, from: history)
            guard contribution.acceptedDistinctSessions >= 0 else { throw BenchmarkAccountError.invalidResponse }
            remoteRecords = try JSONDecoder().decode([BenchmarkOwnedRecord].self, from: records)
            remotePublications = try JSONDecoder().decode([BenchmarkOwnedPublication].self, from: publications)
            contributionSummaries = contribution.history; acceptedComparisons = contribution.acceptedDistinctSessions
            contributionHistory = try readable(history); cloudSessions = try readable(records)
            // Server stores hashes rather than recoverable link capabilities.
            status = "\(remotePublications.filter { $0.revoked_at == nil }.count) active publications. Previously created links cannot be recovered from their hashes."
        }
    }
    func delete(_ lineage: BenchmarkSyncLineage) async {
        await action {
            guard let client, let owner = account.account?.accountID, owner == lineage.owner, let session = lineage.sessionID else { throw BenchmarkSyncError.ownerMismatch }
            let expected = account.generation
            try await client.deleteSession(session, comparisonID: lineage.comparisonID, owner: owner)
            try checkOwner(owner, generation: expected)
            loadLinks(); acceptedComparisons = nil
            status = "Cloud record tombstoned; associated links and contribution are disabled. Cleanup is pending. Local recording is retained."
        }
    }
    func deleteRemoteRecord(_ record: BenchmarkOwnedRecord) async {
        await action {
            guard let client, let owner = account.account?.accountID else { throw BenchmarkAccountError.signedOut }
            let expected = account.generation
            try await client.deleteSession(record.id, comparisonID: record.local_id, owner: owner)
            try checkOwner(owner, generation: expected)
            loadLinks(); acceptedComparisons = nil
            remoteRecords.removeAll { $0.id == record.id }; status = "Cloud record deleted; local My Stats remains. Content cleanup is pending."
        }
    }
    func deleteAccount() async {
        await action {
            guard let client, let owner = account.account?.accountID else { throw BenchmarkAccountError.signedOut }
            let expected = account.generation
            _ = try await client.deleteAccount(owner: owner)
            try checkOwner(owner, generation: expected)
            status = "Account deletion requested. Links and contributions are disabled; cloud content and identity cleanup are pending."
            clearCloudPresentation(); contributionHistory = "Account deletion requested."
        }
    }
    func deletionStatus() async {
        await action {
            guard let client, let owner = account.account?.accountID else { throw BenchmarkAccountError.signedOut }
            let expected = account.generation
            let data = try await client.list("account/deletion", owner: owner)
            try checkOwner(owner, generation: expected)
            let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let deletion = value?["deletion"] as? [String: Any] else { status = "No account deletion requested."; return }
            if deletion["completed_at"] is String { status = "Account deletion completed." }
            else if deletion["content_cleaned_at"] is String {
                status = deletion["blocked_reason"] is String ? "Cloud content removed. Identity deletion needs service configuration." : "Cloud content removed. Identity deletion is still pending or retrying."
            } else { status = "Account deletion requested. Cloud content cleanup is pending." }
        }
    }
}
