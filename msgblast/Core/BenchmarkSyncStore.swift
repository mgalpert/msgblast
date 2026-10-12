import Foundation
import Darwin

public enum BenchmarkSyncError: Error, LocalizedError {
    case invalidJournal, ownerMismatch, changedPrefix, emptySelection, paused, staleOperation, deletedRecord
    public var errorDescription: String? {
        switch self {
        case .deletedRecord: "This cloud comparison was deleted and cannot be uploaded again for this account."
        case .invalidJournal: "The upload journal is damaged; its original bytes are preserved."
        case .ownerMismatch: "These uploads belong to a different account."
        case .changedPrefix: "The recorded prefix differs from the saved upload. Upload stopped."
        case .emptySelection: "Choose a comparison with captured events."
        case .paused: "Private sync is paused."
        case .staleOperation: "The account or upload selection changed."
        }
    }
}
public struct BenchmarkPendingChunk: Codable, Equatable, Sendable {
    public var id: String
    public var sequenceEnd: Int
    public var hash: String
    public var bytes: Data
    public var acknowledged: Bool
}
public struct BenchmarkSyncLineage: Codable, Equatable, Identifiable, Sendable {
    public var id: String { comparisonID }
    public var comparisonID: String
    public var owner: String
    public var sessionID: String?
    public var revision = 1
    public var revisionRequestID: String?
    public var parentSequenceEnd = 0
    public var parentHash = ""
    public var chunks: [BenchmarkPendingChunk] = []
    public var finalizedSequenceEnd = 0
    public var finalizedHash = ""
    public var snapshotID: String?
    public var selectedSequenceEnd = 0
    public var context: String
    public var fixture: Bool
    public var purpose: String
    public var finalized: Bool { snapshotID != nil }
}
public struct BenchmarkSavedPublication: Codable, Equatable, Sendable {
    public var id: String
    public var owner: String
    public var url: URL
    public var projectionHash: String
    public var comparisonID: String?
    public var revoked = false
    public init(id: String, owner: String, url: URL, projectionHash: String, comparisonID: String? = nil) { self.comparisonID = comparisonID; self.id = id; self.owner = owner; self.url = url; self.projectionHash = projectionHash }
}
/// Owner-bound exact bytes and retry identifiers survive process restarts. No
/// credentials are stored here. Upload selection never follows recording.
@MainActor public final class BenchmarkSyncStore {
    private struct Journal: Codable { var schemaVersion = 1; var paused = true; var lineages: [BenchmarkSyncLineage] = []; var publications: [BenchmarkSavedPublication]? = nil; var futureOwner: String? = nil; var excludedComparisons: [String]? = nil; var deletedComparisons: [String: [String]]? = nil }
    private var journal = Journal()
    private var savedBytes: Data?
    public let url: URL
    public var paused: Bool { journal.paused }
    public var futureOwner: String? { journal.futureOwner }
    public var lineages: [BenchmarkSyncLineage] { journal.lineages }
    public var publications: [BenchmarkSavedPublication] { journal.publications ?? [] }
    public init(directory: URL) throws {
        url = directory.appendingPathComponent("Benchmarks/uploads.json")
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let bytes = try Data(contentsOf: url); savedBytes = bytes
                journal = try JSONDecoder().decode(Journal.self, from: bytes)
                guard journal.schemaVersion == 1, Set(journal.lineages.map(\.comparisonID)).count == journal.lineages.count else { throw BenchmarkSyncError.invalidJournal }
                for lineage in journal.lineages {
                    guard !lineage.owner.isEmpty, lineage.chunks.allSatisfy({ PerformanceCanonical.hash($0.bytes) == $0.hash }) else { throw BenchmarkSyncError.invalidJournal }
                }
            } catch { throw BenchmarkSyncError.invalidJournal }
        }
    }
    private func save(_ next: Journal) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.deletingLastPathComponent().path)
        let lockURL = url.deletingLastPathComponent().appendingPathComponent("uploads.lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw BenchmarkSyncError.invalidJournal }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw BenchmarkSyncError.invalidJournal }
        defer { flock(descriptor, LOCK_UN) }
        let current = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        guard current == savedBytes else { throw BenchmarkSyncError.changedPrefix }
        let bytes = try PerformanceCanonical.bytes(next)
        try bytes.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        journal = next; savedBytes = bytes
    }
    public func setFutureSync(enabled: Bool, owner: String, events: [PerformanceEvent]) throws {
        var next = journal
        if enabled {
            next.futureOwner = owner; next.excludedComparisons = Array(Set(events.map(\.comparisonID))).sorted(); next.paused = false
        } else { next.futureOwner = nil; next.paused = true }
        try save(next)
    }
    public func futureComparisons(events: [PerformanceEvent], owner: String) -> [String] {
        guard journal.futureOwner == owner, !paused else { return [] }
        let excluded = Set(journal.excludedComparisons ?? [])
        return Array(Set(events.map(\.comparisonID) + lineages.filter { $0.owner == owner && !$0.finalized }.map(\.comparisonID))).filter { id in
            !(journal.deletedComparisons?[owner] ?? []).contains(id) && (!excluded.contains(id) || lineages.contains { $0.comparisonID == id && $0.owner == owner })
        }.sorted()
    }
    public func pause(_ paused: Bool) throws { var next = journal; next.paused = paused; try save(next) }
    public func update(_ lineage: BenchmarkSyncLineage) throws {
        var next = journal
        if let i = next.lineages.firstIndex(where: { $0.comparisonID == lineage.comparisonID }) {
            guard next.lineages[i].owner == lineage.owner else { throw BenchmarkSyncError.ownerMismatch }
            next.lineages[i] = lineage
        } else { next.lineages.append(lineage) }
        try save(next)
    }
    public func remove(comparisonID: String, owner: String) throws {
        var next = journal
        guard !next.lineages.contains(where: { $0.comparisonID == comparisonID && $0.owner != owner }) else { throw BenchmarkSyncError.ownerMismatch }
        next.lineages.removeAll { $0.comparisonID == comparisonID }
        next.publications = publications.map { link in
            var link = link
            if link.owner == owner && link.comparisonID == comparisonID { link.revoked = true }
            return link
        }
        var deleted = next.deletedComparisons ?? [:]; deleted[owner] = Array(Set((deleted[owner] ?? []) + [comparisonID])); next.deletedComparisons = deleted
        try save(next)
    }
    public func removeAccount(_ owner: String) throws {
        var next = journal; next.lineages.removeAll { $0.owner == owner }; next.publications = publications.filter { $0.owner != owner }; if next.futureOwner == owner { next.futureOwner = nil }; next.paused = true; try save(next)
    }
    public func clearLocalUploads() throws {
        var next = journal; next.lineages = []; next.futureOwner = nil; next.paused = true; try save(next)
    }
    public func savePublication(_ publication: BenchmarkSavedPublication) throws {
        var next = journal; var links = publications
        if let i = links.firstIndex(where: { $0.id == publication.id }) {
            guard links[i].owner == publication.owner else { throw BenchmarkSyncError.ownerMismatch }; links[i] = publication
        } else { links.append(publication) }
        next.publications = links; try save(next)
    }
    public func revokePublication(_ id: String, owner: String) throws {
        guard var link = publications.first(where: { $0.id == id && $0.owner == owner }) else { return }
        link.revoked = true; try savePublication(link)
    }
    public func prepare(events: [PerformanceEvent], comparisonID: String, owner: String, context: String, purpose: String = "sync") throws -> BenchmarkSyncLineage {
        guard !(journal.deletedComparisons?[owner] ?? []).contains(comparisonID) else { throw BenchmarkSyncError.deletedRecord }
        let selected = events.filter { $0.comparisonID == comparisonID }.sorted { $0.sequence < $1.sequence }
        guard !selected.isEmpty else { throw BenchmarkSyncError.emptySelection }
        var lineage = lineages.first { $0.comparisonID == comparisonID } ?? .init(comparisonID: comparisonID, owner: owner, context: context, fixture: selected[0].fixture, purpose: purpose)
        guard lineage.owner == owner else { throw BenchmarkSyncError.ownerMismatch }
        guard lineage.context == context else { throw BenchmarkSyncError.changedPrefix }
        var eventHash: String?
        for (index, event) in selected.enumerated() {
            guard event.sequence == index + 1, event.previousHash == eventHash, event.fixture == lineage.fixture else { throw BenchmarkSyncError.changedPrefix }
            eventHash = PerformanceCanonical.hash(try PerformanceCanonical.bytes(event))
        }
        for chunk in lineage.chunks {
            let saved = try JSONDecoder().decode(PerformanceUploadChunk.self, from: chunk.bytes)
            guard saved.sequenceEnd <= selected.count, Array(selected[(saved.sequenceStart - 1)..<saved.sequenceEnd]) == saved.events else { throw BenchmarkSyncError.changedPrefix }
        }
        let priorEnd = lineage.chunks.last?.sequenceEnd ?? 0
        guard selected.count >= priorEnd else { throw BenchmarkSyncError.changedPrefix }
        if lineage.finalized, selected.count > priorEnd {
            lineage.revision += 1; lineage.revisionRequestID = UUID().uuidString
            lineage.parentSequenceEnd = lineage.finalizedSequenceEnd; lineage.parentHash = lineage.finalizedHash
            lineage.snapshotID = nil
        }
        // Keep existing retry bytes intact; a new selection appends fresh chunks.
        var offset = priorEnd
        while offset < selected.count {
            var end = min(offset + 1000, selected.count)
            let cid = UUID().uuidString
            var bytes: Data
            repeat {
                bytes = try PerformanceCanonical.bytes(PerformanceUploadChunk(id: cid, sessionID: comparisonID, sequenceStart: offset + 1, previousHash: lineage.chunks.last?.hash, events: Array(selected[offset..<end])))
                if bytes.count > 1_048_576 { end = offset + (end - offset) / 2 }
            } while bytes.count > 1_048_576 && end > offset
            guard end > offset, bytes.count <= 1_048_576 else { throw BenchmarkSyncError.changedPrefix }
            lineage.chunks.append(.init(id: cid, sequenceEnd: end, hash: PerformanceCanonical.hash(bytes), bytes: bytes, acknowledged: false)); offset = end
        }
        lineage.selectedSequenceEnd = selected.count
        try update(lineage); return lineage
    }
}
