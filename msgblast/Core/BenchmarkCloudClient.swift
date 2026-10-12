import Foundation

public struct BenchmarkCloudSnapshot: Codable, Equatable, Sendable {
    public var sessionID: String
    public var revision: Int
    public var snapshotID: String
    public var sequenceEnd: Int
    public var hash: String
    public var status: String
}
public enum BenchmarkCloudRetry {
    public static func isRetryable(_ error: Error) -> Bool {
        if case BenchmarkAccountError.http(let status) = error { return [429, 500, 502, 503, 504].contains(status) }
        return (error as? URLError).map { $0.code != .cancelled } ?? false
    }
}
@MainActor public final class BenchmarkCloudClient {
    public let account: BenchmarkAccountSession
    public let store: BenchmarkSyncStore
    private var generation: UInt64 = 0
    public init(account: BenchmarkAccountSession, store: BenchmarkSyncStore) { self.account = account; self.store = store }
    public func pause() throws { generation &+= 1; try store.pause(true) }
    public func resume() throws { try store.pause(false) }
    public func cancel() { generation &+= 1 }
    private func send(_ path: String, method: String = "GET", value: [String: Any]? = nil, bytes: Data? = nil, owner: String) async throws -> Data {
        let body = try bytes ?? value.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys, .withoutEscapingSlashes]) }
        let (data, _) = try await account.request(path: "/api/v1/" + path, method: method, body: body, accountID: owner)
        return data
    }
    private func uploadRequest(_ path: String, value: [String: Any]? = nil, bytes: Data? = nil, owner: String, operation: UInt64, allowPaused: Bool) async throws -> Data {
        for attempt in 0..<3 {
            try check(operation, owner: owner, allowPaused: allowPaused)
            do { return try await send(path, method: "POST", value: value, bytes: bytes, owner: owner) }
            catch {
                guard BenchmarkCloudRetry.isRetryable(error), attempt < 2 else { throw error }
                try await Task.sleep(for: .milliseconds(500 * (1 << attempt)))
            }
        }
        throw BenchmarkAccountError.invalidResponse
    }
    private func check(_ expected: UInt64, owner: String, allowPaused: Bool = false) throws {
        guard expected == generation, account.account?.accountID == owner else { throw BenchmarkSyncError.staleOperation }
        guard allowPaused || !store.paused else { throw BenchmarkSyncError.paused }
    }
    /// Called only after an explicit selection; never observes the local journal.
    public func upload(comparisonID: String, owner: String, contributionSelection: Bool = false) async throws -> BenchmarkCloudSnapshot {
        let operation = generation
        try check(operation, owner: owner, allowPaused: contributionSelection)
        guard var lineage = store.lineages.first(where: { $0.comparisonID == comparisonID }), lineage.owner == owner else { throw BenchmarkSyncError.ownerMismatch }
        if lineage.sessionID == nil {
            let data = try await uploadRequest("sessions", value: ["localID": comparisonID, "purpose": lineage.purpose, "consent": true, "fixture": lineage.fixture, "context": lineage.context], owner: owner, operation: operation, allowPaused: contributionSelection)
            try check(operation, owner: owner, allowPaused: contributionSelection)
            let response = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let session = response?["id"] as? String else { throw BenchmarkAccountError.invalidResponse }
            lineage.sessionID = session; try store.update(lineage)
        }
        let session = lineage.sessionID!
        if let requestID = lineage.revisionRequestID {
            let data = try await uploadRequest("sessions/\(session)/revisions", value: ["consent": true, "requestID": requestID, "parentHash": lineage.parentHash, "parentSequenceEnd": lineage.parentSequenceEnd], owner: owner, operation: operation, allowPaused: contributionSelection)
            try check(operation, owner: owner, allowPaused: contributionSelection)
            let result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard result?["revision"] as? Int == lineage.revision else { throw BenchmarkAccountError.invalidResponse }
            lineage.revisionRequestID = nil; try store.update(lineage)
        }
        for index in lineage.chunks.indices where !lineage.chunks[index].acknowledged {
            let chunk = lineage.chunks[index]
            let data = try await uploadRequest("sessions/\(session)/revisions/\(lineage.revision)/chunks", bytes: chunk.bytes, owner: owner, operation: operation, allowPaused: contributionSelection)
            try check(operation, owner: owner, allowPaused: contributionSelection)
            let receipt = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard receipt?["hash"] as? String == chunk.hash, receipt?["id"] as? String == chunk.id else { throw BenchmarkAccountError.invalidResponse }
            lineage.chunks[index].acknowledged = true; try store.update(lineage)
        }
        guard let tail = lineage.chunks.last else { throw BenchmarkSyncError.emptySelection }
        let data = try await uploadRequest("sessions/\(session)/revisions/\(lineage.revision)/finalize", value: ["sequenceEnd": tail.sequenceEnd, "hash": tail.hash], owner: owner, operation: operation, allowPaused: contributionSelection)
        try check(operation, owner: owner, allowPaused: contributionSelection)
        let snapshot = try JSONDecoder().decode(BenchmarkCloudSnapshot.self, from: data)
        guard snapshot.sessionID == session, snapshot.revision == lineage.revision, snapshot.sequenceEnd == tail.sequenceEnd, snapshot.hash == tail.hash else { throw BenchmarkAccountError.invalidResponse }
        lineage.snapshotID = snapshot.snapshotID; lineage.finalizedHash = tail.hash; lineage.finalizedSequenceEnd = tail.sequenceEnd
        try store.update(lineage); return snapshot
    }
    public func validation(sessionID: String, snapshotID: String, owner: String) async throws -> Data {
        try await send("sessions/\(sessionID)/snapshots/\(snapshotID)/validation", owner: owner)
    }
    public func contributeSelected(_ approval: BenchmarkContributionApproval) async throws -> Data {
        func checkApproval() throws {
            guard account.account?.accountID == approval.owner,
                  BenchmarkContributionApproval(lineage: store.lineages.first { $0.comparisonID == approval.comparisonID }, owner: approval.owner) == approval else { throw BenchmarkSyncError.staleOperation }
        }
        try checkApproval()
        let sessionID = approval.sessionID, snapshotID = approval.snapshotID, owner = approval.owner
        struct History: Decodable { let history: [BenchmarkContributionHistoryEntry] }
        let data = try await send("contributions", owner: owner)
        let history = try JSONDecoder().decode(History.self, from: data).history
        let revision = try BenchmarkContributionSelection.revision(sessionID: sessionID, snapshotID: snapshotID, history: history)
        try checkApproval()
        return try await contribute(sessionID: sessionID, snapshotID: snapshotID, contributionRevision: revision, owner: owner)
    }
    public func contribute(sessionID: String, snapshotID: String, contributionRevision: Int, owner: String) async throws -> Data {
        try await send("sessions/\(sessionID)/contribution", method: "POST", value: ["consent": true, "revision": contributionRevision, "snapshotID": snapshotID], owner: owner)
    }
    public func withdraw(sessionID: String, owner: String) async throws {
        _ = try await send("sessions/\(sessionID)/contribution", method: "DELETE", owner: owner)
    }
    public func publish(_ publication: ComparisonPublication, comparisonID: String, owner: String) async throws -> Data {
        let bytes = try publication.previewBytes()
        let projection = try JSONSerialization.jsonObject(with: bytes)
        guard !comparisonID.isEmpty else { throw BenchmarkSyncError.emptySelection }
        var value: [String: Any] = ["consent": true, "projection": projection, "previewHash": PerformanceCanonical.hash(bytes), "localID": comparisonID]
        if let lineage = store.lineages.first(where: { $0.comparisonID == comparisonID && $0.owner == owner }), let session = lineage.sessionID { value["sessionID"] = session }
        return try await send("publications", method: "POST", value: value, owner: owner)
    }
    public func revoke(publicationID: String, owner: String) async throws {
        _ = try await send("publications/\(publicationID)", method: "DELETE", owner: owner)
    }
    public func list(_ kind: String, owner: String) async throws -> Data {
        guard ["sessions", "publications", "contributions", "statistics", "account/deletion"].contains(kind) else { throw BenchmarkAccountError.invalidResponse }
        return try await send(kind, owner: owner)
    }
    public func deleteSession(_ sessionID: String, comparisonID: String, owner: String) async throws {
        let expected = account.generation
        cancel(); _ = try await send("sessions/\(sessionID)", method: "DELETE", owner: owner)
        guard account.generation == expected, account.account?.accountID == owner else { throw BenchmarkSyncError.staleOperation }
        try store.remove(comparisonID: comparisonID, owner: owner)
    }
    public func deleteAccount(owner: String) async throws -> Data {
        let expected = account.generation
        try pause()
        let data = try await send("account", method: "DELETE", owner: owner)
        guard account.generation == expected, account.account?.accountID == owner else { throw BenchmarkSyncError.staleOperation }
        try store.removeAccount(owner); return data
    }
}
