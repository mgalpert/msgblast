import Foundation
import CryptoKit

/// A reconstruction from an allowlist, never a redacted copy of the raw IPS file.
public struct CrashReport: Codable, Equatable, Sendable {
    public struct Frame: Codable, Equatable, Sendable {
        public let uuid: String
        public let arch: String
        public let offset: Int
    }
    public let schema: Int
    public let incident: String
    public let process: String
    public let bundleIdentifier: String
    public let version: String
    public let build: String
    public let exception: String
    public let signal: String
    public let day: String
    public let frames: [Frame]
    public let fingerprint: String
    public var preview: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: (try? encoder.encode(self)) ?? Data(), as: UTF8.self)
    }
    public static let maximumFileBytes = 2 * 1024 * 1024
    private static func token(_ value: Any?) -> String {
        guard let text = value as? String, text.range(of: #"^[0-9A-Za-z._-]{1,32}$"#, options: .regularExpression) != nil else { return "unknown" }
        return text
    }
    public static func parse(_ data: Data, bundleIdentifier: String, appPath: String, now: Date = Date()) -> CrashReport? {
        guard data.count <= maximumFileBytes, let newline = data.firstIndex(of: 10),
              let header = (try? JSONSerialization.jsonObject(with: data[..<newline])) as? [String: Any],
              header["bug_type"] as? String == "309",
              let body = (try? JSONSerialization.jsonObject(with: data[data.index(after: newline)...])) as? [String: Any],
              let incident = (header["incident_id"] as? String).flatMap(UUID.init(uuidString:)),
              let path = body["procPath"] as? String,
              let capture = body["captureTime"] as? String else { return nil }
        let info = body["bundleInfo"] as? [String: Any] ?? [:]
        let process: String
        if info["CFBundleIdentifier"] as? String == bundleIdentifier,
           path == appPath + "/Contents/MacOS/msgblast" { process = "app" }
        else if path == appPath + "/Contents/Helpers/cloudflared" { process = "helper" }
        else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS Z"
        guard let date = formatter.date(from: capture), date <= now,
              now.timeIntervalSince(date) <= 30 * 86400,
              let exception = body["exception"] as? [String: Any],
              let type = exception["type"] as? String,
              ["EXC_BAD_ACCESS", "EXC_BAD_INSTRUCTION", "EXC_ARITHMETIC", "EXC_BREAKPOINT", "EXC_CRASH", "EXC_GUARD", "EXC_RESOURCE"].contains(type),
              let signal = exception["signal"] as? String,
              ["SIGABRT", "SIGSEGV", "SIGBUS", "SIGILL", "SIGTRAP", "SIGFPE", "SIGSYS"].contains(signal),
              let images = body["usedImages"] as? [[String: Any]],
              let threads = body["threads"] as? [[String: Any]],
              let thread = threads.first(where: { $0["triggered"] as? Bool == true }),
              let rawFrames = thread["frames"] as? [[String: Any]] else { return nil }
        let frames: [Frame] = rawFrames.prefix(64).compactMap { frame in
            guard let index = frame["imageIndex"] as? Int, images.indices.contains(index),
                  let offset = frame["imageOffset"] as? Int, offset >= 0, offset <= 0x1fffffffffffff,
                  let uuid = (images[index]["uuid"] as? String).flatMap(UUID.init(uuidString:)),
                  let arch = images[index]["arch"] as? String, ["arm64", "arm64e", "x86_64", "x86_64h"].contains(arch) else { return nil }
            return Frame(uuid: uuid.uuidString.lowercased(), arch: arch, offset: offset)
        }
        guard !frames.isEmpty else { return nil }
        // UUIDs plus offsets group the same stack within a build, independently of ASLR.
        let signature = ([process, type, signal] + frames.prefix(12).map { "\($0.uuid):\($0.offset)" }).joined(separator: "|")
        let fingerprint = SHA256.hash(data: Data(signature.utf8)).map { String(format: "%02x", $0) }.joined()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return CrashReport(schema: 1, incident: incident.uuidString.lowercased(), process: process,
                           bundleIdentifier: bundleIdentifier, version: token(info["CFBundleShortVersionString"]),
                           build: token(info["CFBundleVersion"]), exception: type, signal: signal,
                           day: formatter.string(from: date), frames: frames, fingerprint: fingerprint)
    }

    public static func collect(directory: URL, bundleIdentifier: String, appPath: String, now: Date = Date()) -> [CrashReport] {
        let manager = FileManager.default
        var reports: [CrashReport] = []
        for folder in [directory, directory.appendingPathComponent("Retired")] {
            let urls = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])) ?? []
            for url in urls where url.pathExtension == "ips" && (url.lastPathComponent.lowercased().hasPrefix("msgblast") || url.lastPathComponent.hasPrefix("cloudflared")) {
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]),
                      values.isRegularFile == true, values.isSymbolicLink != true,
                      let size = values.fileSize, size <= maximumFileBytes,
                      let modified = values.contentModificationDate, now.timeIntervalSince(modified) <= 31 * 86400,
                      let handle = try? FileHandle(forReadingFrom: url) else { continue }
                // Bounded read even if the file grows after stat.
                let data = try? handle.read(upToCount: maximumFileBytes + 1)
                try? handle.close()
                if let data, let report = parse(data, bundleIdentifier: bundleIdentifier, appPath: appPath, now: now) { reports.append(report) }
            }
        }
        var seen = Set<String>()
        return reports.sorted { $0.day > $1.day }.filter { seen.insert($0.incident).inserted }
    }
}

public struct CrashAttempt: Codable, Equatable, Sendable {
    public let id: UUID
    public let report: CrashReport
    public let note: String
}

/// Independent of state.json and permissions. Fail closed if the journal cannot be read/written.
public final class CrashReportStore {
    private struct Journal: Codable {
        var dismissed: Set<String> = []
        var submitted: Set<String> = []
        var attempts: [String: CrashAttempt] = [:]
    }
    private let url: URL
    private var journal: Journal
    public init(directory: URL) throws {
        url = directory.appendingPathComponent("crash-reports.json")
        do { journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: url)) }
        catch CocoaError.fileReadNoSuchFile { journal = Journal() }
    }
    public var pendingReports: [CrashReport] { journal.attempts.values.map(\.report).sorted { $0.day > $1.day } }
    public func shouldOffer(_ report: CrashReport) -> Bool { !journal.dismissed.contains(report.incident) && !isSubmitted(report) }
    public func isSubmitted(_ report: CrashReport) -> Bool { journal.submitted.contains(report.incident) }
    public func attempt(_ report: CrashReport) -> CrashAttempt? { journal.attempts[report.incident] }
    public func dismiss(_ report: CrashReport) throws {
        guard !journal.dismissed.contains(report.incident) else { return }
        var next = journal; next.dismissed.insert(report.incident); try save(next)
    }
    public func prepare(_ report: CrashReport, note: String) throws -> CrashAttempt {
        guard !isSubmitted(report) else { throw FeedbackSubmissionError.rejected }
        if let previous = attempt(report) { return previous }
        let attempt = CrashAttempt(id: UUID(), report: report, note: note)
        var next = journal; next.attempts[report.incident] = attempt
        try save(next)
        return attempt
    }
    public func confirm(_ report: CrashReport) throws {
        var next = journal; next.submitted.insert(report.incident); next.attempts.removeValue(forKey: report.incident)
        try save(next)
    }
    private func save(_ next: Journal) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(next)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        journal = next
    }
}
