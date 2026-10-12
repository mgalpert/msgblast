import Foundation

public struct BenchmarkContributionHistoryEntry: Decodable, Equatable, Sendable, Identifiable {
    public var id: String { session }
    public let session: String
    public let revision: Int
    public let snapshotID: String
    public let status: String
    public let reasons: [String]
    public let completeness: String?
    public init(session: String, revision: Int, snapshotID: String, status: String, reasons: [String] = [], completeness: String? = nil) {
        self.session = session; self.revision = revision; self.snapshotID = snapshotID; self.status = status; self.reasons = reasons; self.completeness = completeness
    }
}
public enum BenchmarkContributionSelection {
    /// History is fetched through the verified owner's account before each
    /// explicit choice. An accepted retry keeps its existing immutable binding.
    public static func revision(sessionID: String, snapshotID: String, history: [BenchmarkContributionHistoryEntry]) throws -> Int {
        let entries = history.filter { $0.session == sessionID }
        guard entries.allSatisfy({ (1...10000).contains($0.revision) }) else { throw BenchmarkAccountError.invalidResponse }
        guard let latest = entries.max(by: { $0.revision < $1.revision }) else { return 1 }
        if latest.snapshotID == snapshotID, latest.status != "withdrawn" { return latest.revision }
        guard latest.revision < 10000 else { throw BenchmarkAccountError.quota }
        return latest.revision + 1
    }
}

/// Explicit approval belongs to one verified owner and one finalized prefix.
public struct BenchmarkContributionApproval: Equatable, Sendable {
    public let comparisonID: String
    public let owner: String
    public let sessionID: String
    public let snapshotID: String
    public init?(lineage: BenchmarkSyncLineage?, owner: String?) {
        guard let lineage, let owner, lineage.owner == owner,
              let session = lineage.sessionID, let snapshot = lineage.snapshotID else { return nil }
        comparisonID = lineage.comparisonID; self.owner = owner; sessionID = session; snapshotID = snapshot
    }
}
