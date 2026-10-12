import Foundation
import Darwin

/// Immutable durable lines. A torn append or competing writer stops capture;
/// recovery never truncates or silently replaces the original bytes.
public final class PerformanceStore {
    public let url: URL
    public private(set) var events: [PerformanceEvent] = []
    private var hashes: [String: String] = [:]
    private var positions: [String: Int] = [:]
    private var byteCount: Int64 = 0
    public init(directory: URL) throws {
        url = directory.appendingPathComponent("Performance/events.jsonl")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard flock(handle.fileDescriptor, LOCK_SH) == 0 else { throw Self.posixError() }
        defer { flock(handle.fileDescriptor, LOCK_UN) }
        let bytes = try handle.readToEnd() ?? Data()
        guard bytes.isEmpty || bytes.last == 10 else { throw PerformanceStoreError.damagedJournal }
        for line in bytes.split(separator: 10) {
            let data = Data(line)
            let event = try JSONDecoder().decode(PerformanceEvent.self, from: data)
            guard event.schemaVersion == 1, event.sequence == (positions[event.comparisonID] ?? 0) + 1,
                  event.previousHash == hashes[event.comparisonID], try PerformanceCanonical.bytes(event) == data else {
                throw PerformanceStoreError.damagedJournal
            }
            events.append(event)
            hashes[event.comparisonID] = PerformanceCanonical.hash(data)
            positions[event.comparisonID] = event.sequence
        }
        byteCount = Int64(bytes.count)
    }
    public func append(_ input: PerformanceEvent) throws -> PerformanceEvent {
        var event = input
        event.sequence = (positions[input.comparisonID] ?? 0) + 1
        event.previousHash = hashes[input.comparisonID]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let canonical = try PerformanceCanonical.bytes(event)
        var line = canonical; line.append(10)
        let descriptor = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw Self.posixError() }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw Self.posixError() }
        defer { flock(descriptor, LOCK_UN) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw Self.posixError() }
        guard metadata.st_size == byteCount else { throw PerformanceStoreError.concurrentWriter }
        try line.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw Self.posixError() }
                offset += written
            }
        }
        while fsync(descriptor) != 0 { if errno != EINTR { throw Self.posixError() } }
        byteCount += Int64(line.count)
        events.append(event)
        hashes[event.comparisonID] = PerformanceCanonical.hash(canonical)
        positions[event.comparisonID] = event.sequence
        return event
    }
    public func deleteAll() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        events = []; hashes = [:]; positions = [:]; byteCount = 0
    }
    private static func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
public enum PerformanceStoreError: LocalizedError {
    case damagedJournal, concurrentWriter
    public var errorDescription: String? {
        switch self {
        case .damagedJournal: "The performance journal is damaged. Original bytes are preserved; recording is unavailable until repaired or explicitly deleted."
        case .concurrentWriter: "Another writer changed the performance journal. Recording stopped to preserve committed bytes; reopen the app before recording again."
        }
    }
}
