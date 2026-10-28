import Foundation

/// Local feedback package. The diagnostic file is an allowlist of counts and
/// categories. It is omitted unless the caller passes `includeDiagnostics: true`.
/// This type does not read Messages, Contacts, drafts, or the network.
public enum DiagnosticReport {
    public static let maximumNoteLength = 8000
    public static let packageNames = ["README.txt", "feedback.txt", "diagnostics.json"]
    public static let diagnosticKeys = [
        "agentCount", "attachmentCount", "buildNumber", "bundleIdentifier", "comparisonCount",
        "fixtureMode", "hasDraft", "lastErrorCategory", "messagesStatus", "operatingSystem",
        "permissionStage", "personalAgent", "stateFileBytes", "stateFilePresent", "supportFolder",
        "updatesEnabled", "updatesReason", "variant", "version", "webProviderCounts", "windowStyle"
    ]
    public static let excludedTopics = [
        "message text",
        "contacts and phone numbers",
        "drafts and prompts",
        "attachments",
        "chat history and chat.db",
        "cookies, tokens, and saved website sessions",
        "the contents of state.json",
        "home-directory paths"
    ]

    public static func isValidContact(_ raw: String) -> Bool {
        let contact = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard contact.count <= 120 else { return false }
        return contact.range(of: #"^[A-Za-z0-9._%+-]{1,64}@[A-Za-z0-9.-]{1,253}\.[A-Za-z]{2,24}$"#, options: .regularExpression) != nil
    }

    public static func diagnosticsJSON(_ facts: DiagnosticFacts) -> String {
        let payload = DiagnosticPayload(facts)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = (try? encoder.encode(payload)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    public static func make(_ request: DiagnosticRequest, now: Date = Date()) throws -> DiagnosticPackage {
        let note = plain(request.note).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else { throw DiagnosticReportError.emptyNote }
        guard note.count <= maximumNoteLength else { throw DiagnosticReportError.noteTooLong }
        let contact = request.contact.trimmingCharacters(in: .whitespacesAndNewlines)
        if !contact.isEmpty && !isValidContact(contact) { throw DiagnosticReportError.invalidContact }
        let json = diagnosticsJSON(request.facts)
        var files: [(String, Data)] = [
            ("README.txt", Data(readme(included: request.includeDiagnostics).utf8)),
            ("feedback.txt", Data(feedbackText(kind: request.kind, contact: contact, note: note, now: now).utf8))
        ]
        if request.includeDiagnostics {
            files.append(("diagnostics.json", Data(json.utf8)))
        }
        return DiagnosticPackage(
            kind: request.kind,
            includeDiagnostics: request.includeDiagnostics,
            suggestedFilename: request.kind.filename,
            files: files,
            archive: try DiagnosticArchive.archive(files),
            diagnosticsPreview: request.includeDiagnostics ? json : nil)
    }

    private static func readme(included: Bool) -> String {
        let choice = included ? "included" : "not included"
        let topics = excludedTopics.map { "- \($0)" }.joined(separator: "\n")
        return """
        msgblast feedback package
        Diagnostics: \(choice)

        This ZIP is a local copy created when you choose Save.
        Send feedback submits your note, optional reply address, and chosen diagnostics privately to the msgblast team.

        feedback.txt is the note you typed. A reply address appears there only when you enter one.
        diagnostics.json is a separate opt-in file. It is \(choice).

        diagnostics.json never includes:
        \(topics)

        """
    }

    private static func feedbackText(kind: DiagnosticReportKind, contact: String, note: String, now: Date) -> String {
        let reply = contact.isEmpty ? "not provided" : contact
        return """
        Kind: \(kind.label)
        Date: \(Self.utcDay(now))
        Contact: \(reply)

        \(note)

        """
    }

    private static func utcDay(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func plain(_ raw: String) -> String {
        String(raw.map { character in
            if character == "\n" || character == "\t" || character == "\r" { return character }
            return character.unicodeScalars.allSatisfy { $0.value >= 32 } ? character : " "
        })
    }
}

public enum DiagnosticReportKind: String, Codable, CaseIterable, Sendable {
    case feedback, bug
    public var label: String { self == .bug ? "Bug report" : "Feedback" }
    public var filename: String { self == .bug ? "msgblast-bug-report.zip" : "msgblast-feedback.zip" }
}

public struct DiagnosticRequest: Sendable, Equatable {
    public var kind: DiagnosticReportKind
    public var note: String
    public var contact: String
    public var includeDiagnostics: Bool
    public var facts: DiagnosticFacts
    public init(kind: DiagnosticReportKind, note: String, contact: String = "", includeDiagnostics: Bool = false, facts: DiagnosticFacts) {
        self.kind = kind
        self.note = note
        self.contact = contact
        self.includeDiagnostics = includeDiagnostics
        self.facts = facts
    }
}

public struct DiagnosticFacts: Sendable, Equatable {
    public var version: String
    public var buildNumber: String
    public var bundleIdentifier: String
    public var fixtureMode: Bool
    public var operatingSystem: String
    public var updatesEnabled: Bool
    public var updatesReason: String
    public var messagesStatus: String
    public var permissionStage: String
    public var agentCount: Int
    public var comparisonCount: Int
    public var hasDraft: Bool
    public var attachmentCount: Int
    public var windowStyle: String
    public var personalAgent: String
    public var webProviderCounts: [String: Int]
    public var lastError: String?
    public var supportFolder: String
    public var stateFilePresent: Bool
    public var stateFileBytes: Int

    public init(version: String, buildNumber: String, bundleIdentifier: String, fixtureMode: Bool, operatingSystem: String, updatesEnabled: Bool, updatesReason: String, messagesStatus: String, permissionStage: String, agentCount: Int, comparisonCount: Int, hasDraft: Bool, attachmentCount: Int, windowStyle: String, personalAgent: String, webProviderCounts: [String: Int], lastError: String?, supportFolder: String, stateFilePresent: Bool, stateFileBytes: Int) {
        self.version = version
        self.buildNumber = buildNumber
        self.bundleIdentifier = bundleIdentifier
        self.fixtureMode = fixtureMode
        self.operatingSystem = operatingSystem
        self.updatesEnabled = updatesEnabled
        self.updatesReason = updatesReason
        self.messagesStatus = messagesStatus
        self.permissionStage = permissionStage
        self.agentCount = agentCount
        self.comparisonCount = comparisonCount
        self.hasDraft = hasDraft
        self.attachmentCount = attachmentCount
        self.windowStyle = windowStyle
        self.personalAgent = personalAgent
        self.webProviderCounts = webProviderCounts
        self.lastError = lastError
        self.supportFolder = supportFolder
        self.stateFilePresent = stateFilePresent
        self.stateFileBytes = stateFileBytes
    }

    public static func empty(bundleIdentifier: String = "unknown", operatingSystem: String = "unknown") -> DiagnosticFacts {
        DiagnosticFacts(version: "unknown", buildNumber: "unknown", bundleIdentifier: bundleIdentifier, fixtureMode: false, operatingSystem: operatingSystem, updatesEnabled: false, updatesReason: "", messagesStatus: "", permissionStage: "idle", agentCount: 0, comparisonCount: 0, hasDraft: false, attachmentCount: 0, windowStyle: "connected", personalAgent: "", webProviderCounts: [:], lastError: nil, supportFolder: "", stateFilePresent: false, stateFileBytes: 0)
    }
}

struct DiagnosticPayload: Codable, Equatable {
    var agentCount: Int
    var attachmentCount: Int
    var buildNumber: String
    var bundleIdentifier: String
    var comparisonCount: Int
    var fixtureMode: Bool
    var hasDraft: Bool
    var lastErrorCategory: String
    var messagesStatus: String
    var operatingSystem: String
    var permissionStage: String
    var personalAgent: String
    var stateFileBytes: Int
    var stateFilePresent: Bool
    var supportFolder: String
    var updatesEnabled: Bool
    var updatesReason: String
    var variant: String
    var version: String
    var webProviderCounts: [String: Int]
    var windowStyle: String

    init(_ facts: DiagnosticFacts) {
        version = DiagnosticPayload.token(facts.version, pattern: #"^[0-9A-Za-z._-]{1,32}$"#)
        buildNumber = DiagnosticPayload.token(facts.buildNumber, pattern: #"^[0-9A-Za-z._-]{1,32}$"#)
        let bundle = DiagnosticPayload.token(facts.bundleIdentifier, pattern: #"^com\.msgblast\.[A-Za-z0-9-]{1,40}(?:\.[A-Za-z0-9-]{1,40})?$"#)
        bundleIdentifier = bundle
        variant = DiagnosticPayload.variant(for: bundle)
        fixtureMode = facts.fixtureMode
        operatingSystem = DiagnosticPayload.token(facts.operatingSystem, pattern: #"^Version [0-9]+(?:\.[0-9]+){1,3} \(Build [0-9A-Za-z]{1,32}\)$"#)
        updatesEnabled = facts.updatesEnabled
        updatesReason = DiagnosticPayload.updatesReason(facts.updatesReason)
        messagesStatus = DiagnosticPayload.messagesStatus(facts.messagesStatus)
        permissionStage = DiagnosticPayload.choice(facts.permissionStage, allowed: ["idle", "openingSettings", "guiding", "waitingForAccess", "verified"])
        agentCount = DiagnosticPayload.count(facts.agentCount)
        comparisonCount = DiagnosticPayload.count(facts.comparisonCount)
        hasDraft = facts.hasDraft
        attachmentCount = DiagnosticPayload.count(facts.attachmentCount)
        windowStyle = DiagnosticPayload.choice(facts.windowStyle, allowed: ["connected", "separate"], fallback: "unknown")
        personalAgent = PersonalAgentProvider(rawValue: facts.personalAgent)?.rawValue ?? "none"
        webProviderCounts = Dictionary(uniqueKeysWithValues: facts.webProviderCounts.compactMap { key, value in
            guard WebProvider(rawValue: key) != nil, value > 0 else { return nil }
            return (key, DiagnosticPayload.count(value))
        })
        lastErrorCategory = DiagnosticPayload.errorCategory(facts.lastError)
        supportFolder = DiagnosticPayload.supportFolder(facts.supportFolder)
        stateFilePresent = facts.stateFilePresent && facts.stateFileBytes >= 0
        stateFileBytes = stateFilePresent ? min(facts.stateFileBytes, 512_000_000) : 0
    }

    private static func token(_ raw: String, pattern: String) -> String {
        raw.range(of: pattern, options: .regularExpression) != nil ? raw : "unknown"
    }

    private static func choice(_ raw: String, allowed: [String], fallback: String = "unknown") -> String {
        allowed.contains(raw) ? raw : fallback
    }

    private static func count(_ value: Int) -> Int { min(max(value, 0), 1_000_000) }

    private static func variant(for bundle: String) -> String {
        if AppBundleIdentity.isDevelopment(bundle) { return "development" }
        switch bundle {
        case AppBundleIdentity.production: return "production"
        case "com.msgblast.demo": return "demo"
        default: return "other"
        }
    }

    private static func updatesReason(_ raw: String) -> String {
        let allowed = [
            "",
            "Updates are disabled in previews and test runs.",
            "This development build has no configured update service."
        ]
        return allowed.contains(raw) ? raw : "unavailable"
    }

    private static func messagesStatus(_ raw: String) -> String {
        switch raw {
        case "Checking Messages history…": "checking"
        case "Messages history available · read-only": "available"
        case "Simulated Messages · no real sends": "simulated"
        case "Permission guide preview · history access is simulated as unavailable · no real sends": "permissionPreview"
        default: "unavailable"
        }
    }

    private static func supportFolder(_ raw: String) -> String {
        if raw == "msgblast" || raw == "MsgBlast-WebPreview" { return raw }
        return SupportDirectory.sanitized(raw) ?? "unknown"
    }

    private static func errorCategory(_ raw: String?) -> String {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "none" }
        let value = raw.lowercased()
        if value.contains("full disk") || value.contains("messages history") { return "messagesAccess" }
        if value.contains("contacts") { return "contacts" }
        if value.contains("save") || value.contains("storage") || value.contains("state") { return "storage" }
        if value.contains("automation") || value.contains("destination") || value.contains("send") { return "send" }
        return "other"
    }
}

public struct DiagnosticPackage: Sendable, Equatable {
    public var kind: DiagnosticReportKind
    public var includeDiagnostics: Bool
    public var suggestedFilename: String
    public var files: [(String, Data)]
    public var archive: Data
    public var diagnosticsPreview: String?
    public static func == (lhs: DiagnosticPackage, rhs: DiagnosticPackage) -> Bool {
        lhs.kind == rhs.kind && lhs.includeDiagnostics == rhs.includeDiagnostics && lhs.suggestedFilename == rhs.suggestedFilename
            && lhs.files.elementsEqual(rhs.files, by: { $0.0 == $1.0 && $0.1 == $1.1 }) && lhs.archive == rhs.archive && lhs.diagnosticsPreview == rhs.diagnosticsPreview
    }
}

public enum DiagnosticReportError: LocalizedError, Equatable {
    case emptyNote, noteTooLong, invalidContact, rejectedFile(String), rejectedDestination, unreadableArchive
    public var errorDescription: String? {
        switch self {
        case .emptyNote: "Write a short note before saving the report."
        case .noteTooLong: "Shorten the note to \(DiagnosticReport.maximumNoteLength) characters."
        case .invalidContact: "Leave the reply address blank or enter an email address."
        case .rejectedFile: "That file cannot be added to a feedback report."
        case .rejectedDestination: "Choose a file name for the report."
        case .unreadableArchive: "The feedback report could not be read back."
        }
    }
}

public enum DiagnosticArchive {
    public static func archive(_ files: [(String, Data)]) throws -> Data {
        var seen = Set<String>()
        var locals: [(name: String, data: Data, crc: UInt32, offset: UInt32)] = []
        var body = Data()
        for (name, data) in files {
            guard DiagnosticReport.packageNames.contains(name), seen.insert(name).inserted else { throw DiagnosticReportError.rejectedFile(name) }
            let crc = ZipChecksum.crc32(data)
            let offset = UInt32(body.count)
            body.append(localHeader(name: name, data: data, crc: crc))
            locals.append((name, data, crc, offset))
        }
        let directoryStart = UInt32(body.count)
        var directory = Data()
        for entry in locals {
            directory.append(centralHeader(name: entry.name, data: entry.data, crc: entry.crc, offset: entry.offset))
        }
        body.append(directory)
        body.append(endRecord(count: UInt16(locals.count), size: UInt32(directory.count), start: directoryStart))
        return body
    }

    public static func entries(_ archive: Data) throws -> [String: Data] {
        var offset = 0
        var found: [String: Data] = [:]
        while offset + 30 <= archive.count {
            let signature = archive.readUInt32(offset)
            if signature == 0x02014b50 { return found }
            guard signature == 0x04034b50 else { throw DiagnosticReportError.unreadableArchive }
            let method = archive.readUInt16(offset + 8)
            let crc = archive.readUInt32(offset + 14)
            let size = Int(archive.readUInt32(offset + 18))
            let nameLength = Int(archive.readUInt16(offset + 26))
            let extraLength = Int(archive.readUInt16(offset + 28))
            let nameStart = offset + 30
            let dataStart = nameStart + nameLength + extraLength
            guard method == 0, dataStart + size <= archive.count else { throw DiagnosticReportError.unreadableArchive }
            let name = String(decoding: archive[nameStart..<(nameStart + nameLength)], as: UTF8.self)
            guard DiagnosticReport.packageNames.contains(name) else { throw DiagnosticReportError.rejectedFile(name) }
            let data = Data(archive[dataStart..<(dataStart + size)])
            guard ZipChecksum.crc32(data) == crc else { throw DiagnosticReportError.unreadableArchive }
            found[name] = data
            offset = dataStart + size
        }
        guard !found.isEmpty else { throw DiagnosticReportError.unreadableArchive }
        return found
    }

    public static func write(_ data: Data, to url: URL) throws {
        var directory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue {
            throw DiagnosticReportError.rejectedDestination
        }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func writeTemporary(_ package: DiagnosticPackage) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("msgblast-feedback-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent(package.suggestedFilename)
        try write(package.archive, to: url)
        return url
    }

    private static func localHeader(name: String, data: Data, crc: UInt32) -> Data {
        let bytes = Array(name.utf8)
        var header = Data()
        header.appendUInt32(0x04034b50)
        header.appendUInt16(20)
        header.appendUInt16(1 << 11)
        header.appendUInt16(0)
        header.appendUInt16(ZipChecksum.dosTime)
        header.appendUInt16(ZipChecksum.dosDate)
        header.appendUInt32(crc)
        header.appendUInt32(UInt32(data.count))
        header.appendUInt32(UInt32(data.count))
        header.appendUInt16(UInt16(bytes.count))
        header.appendUInt16(0)
        header.append(contentsOf: bytes)
        header.append(data)
        return header
    }

    private static func centralHeader(name: String, data: Data, crc: UInt32, offset: UInt32) -> Data {
        let bytes = Array(name.utf8)
        var header = Data()
        header.appendUInt32(0x02014b50)
        header.appendUInt16((3 << 8) | 20)
        header.appendUInt16(20)
        header.appendUInt16(1 << 11)
        header.appendUInt16(0)
        header.appendUInt16(ZipChecksum.dosTime)
        header.appendUInt16(ZipChecksum.dosDate)
        header.appendUInt32(crc)
        header.appendUInt32(UInt32(data.count))
        header.appendUInt32(UInt32(data.count))
        header.appendUInt16(UInt16(bytes.count))
        header.appendUInt16(0)
        header.appendUInt16(0)
        header.appendUInt16(0)
        header.appendUInt16(0)
        header.appendUInt32(UInt32(0o100600) << 16)
        header.appendUInt32(offset)
        header.append(contentsOf: bytes)
        return header
    }

    private static func endRecord(count: UInt16, size: UInt32, start: UInt32) -> Data {
        var record = Data()
        record.appendUInt32(0x06054b50)
        record.appendUInt16(0)
        record.appendUInt16(0)
        record.appendUInt16(count)
        record.appendUInt16(count)
        record.appendUInt32(size)
        record.appendUInt32(start)
        record.appendUInt16(0)
        return record
    }
}

private enum ZipChecksum {
    static let dosTime: UInt16 = 0
    static let dosDate: UInt16 = (46 << 9) | (1 << 5) | 1
    private static let table: [UInt32] = (0..<256).map { index in
        var crc = UInt32(index)
        for _ in 0..<8 { crc = (crc & 1) == 1 ? (0xEDB88320 ^ (crc >> 1)) : (crc >> 1) }
        return crc
    }
    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
    mutating func appendUInt32(_ value: UInt32) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
    func readUInt16(_ offset: Int) -> UInt16 {
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }
    func readUInt32(_ offset: Int) -> UInt32 {
        UInt32(self[offset]) | (UInt32(self[offset + 1]) << 8) | (UInt32(self[offset + 2]) << 16) | (UInt32(self[offset + 3]) << 24)
    }
}
