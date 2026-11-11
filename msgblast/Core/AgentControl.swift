import Foundation

/// How much an outside agent may do. Approval in msgblast picks one level per agent.
/// Raw values are saved; 1 was a removed middle level and must never read as Full access.
public enum AgentControlAccess: Int, Codable, CaseIterable, Comparable, Sendable {
    case readOnly = 0, full = 2
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    public var label: String {
        switch self { case .readOnly: "Read only"; case .full: "Full access" }
    }
}

public enum AgentControlError: LocalizedError, Equatable {
    case unknownTool(String), needsAccess(AgentControlAccess), invalidArguments(String), notFound(String)
    public var errorDescription: String? {
        switch self {
        case .unknownTool(let name): "No msgblast tool is named \(name)."
        case .needsAccess(let level): "This needs \(level.label) access in msgblast."
        case .invalidArguments(let detail): "Invalid arguments: \(detail)"
        case .notFound(let id): "Nothing in msgblast matches \(id)."
        }
    }
}

/// One tool as MCP and the CLI advertise it. Schemas are JSON Schema text.
public struct AgentControlTool: Sendable {
    public let name: String, title: String, summary: String
    public let access: AgentControlAccess
    public let inputSchema: String
}

public struct AgentControlAgent: Codable, Equatable, Sendable {
    public var id: String, name: String, kind: String
    public var visible: Bool, selected: Bool, busy: Bool
    public init(id: String, name: String, kind: String, visible: Bool, selected: Bool, busy: Bool) {
        self.id = id; self.name = name; self.kind = kind; self.visible = visible; self.selected = selected; self.busy = busy
    }
}

public struct AgentControlStatus: Codable, Equatable, Sendable {
    public var version: String, permissions: [String: Bool], busyAgents: [String]
    public init(version: String, permissions: [String: Bool], busyAgents: [String]) {
        self.version = version; self.permissions = permissions; self.busyAgents = busyAgents
    }
}

public struct AgentControlTurn: Codable, Equatable, Sendable {
    /// Nil for website and app turns, whose pages do not show a time.
    public var agent: String, outgoing: Bool, text: String, date: Date?
    public init(agent: String, outgoing: Bool, text: String, date: Date?) {
        self.agent = agent; self.outgoing = outgoing; self.text = text; self.date = date
    }
}

public struct AgentControlComparisonSummary: Codable, Equatable, Sendable {
    public var id: UUID, title: String, created: Date, ended: Date?, agents: [String]
}

public struct AgentControlComparison: Codable, Equatable, Sendable {
    public var id: UUID, prompt: String, created: Date, ended: Date?
    public var submissions: [String: String], turns: [AgentControlTurn]
}

/// What the running app provides. `AppModel` conforms in the app target.
@MainActor public protocol AgentControlHost: AnyObject {
    func controlStatus() -> AgentControlStatus
    func controlAgents() -> [AgentControlAgent]
    func controlComparisons() -> [Comparison]
    func controlTranscript(_ comparison: Comparison) -> [AgentControlTurn]
    var controlEvents: AgentControlEvents { get }
}

public struct AgentControlWaitResult: Codable, Equatable, Sendable {
    public var events: [AgentControlEvent], next: Int
}

@MainActor public enum AgentControl {
    public static let tools: [AgentControlTool] = [
        AgentControlTool(name: "msgblast_status", title: "msgblast status",
                         summary: "Version, which macOS permissions msgblast has, and which agents are busy.",
                         access: .readOnly, inputSchema: #"{"type":"object","properties":{}}"#),
        AgentControlTool(name: "msgblast_agents_list", title: "List agents",
                         summary: "Agents msgblast can send to. Hidden agents only with includeHidden.",
                         access: .readOnly, inputSchema: #"{"type":"object","properties":{"includeHidden":{"type":"boolean"}}}"#),
        AgentControlTool(name: "msgblast_comparisons_list", title: "List comparisons",
                         summary: "Saved comparisons, newest first. query filters by name or prompt.",
                         access: .readOnly, inputSchema: #"{"type":"object","properties":{"query":{"type":"string"},"limit":{"type":"integer","minimum":1,"maximum":100}}}"#),
        AgentControlTool(name: "msgblast_mentions", title: "Mention comparisons",
                         summary: "Comparisons whose name or prompt matches query, as resource links for @-mentions. query may be empty.",
                         access: .readOnly, inputSchema: #"{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}"#),
        AgentControlTool(name: "msgblast_comparison_read", title: "Read a comparison",
                         summary: "A comparison's prompt, each agent's submission state, and the conversation so far.",
                         access: .readOnly, inputSchema: #"{"type":"object","properties":{"id":{"type":"string"}},"required":["id"]}"#),
        AgentControlTool(name: "msgblast_blast_wait", title: "Wait for replies",
                         summary: "Waits up to timeoutSeconds for events after cursor `after` (a reply arrived, a send finished, an agent turned busy or ready). Returns them with `next`. Empty events: nothing happened yet; end your turn or call again with `next`.",
                         access: .readOnly, inputSchema: #"{"type":"object","properties":{"after":{"type":"integer","minimum":0},"comparisonId":{"type":"string"},"timeoutSeconds":{"type":"integer","minimum":0,"maximum":300}}}"#)
    ]

    /// Runs one tool. Arguments and the result are JSON.
    public static func call(_ name: String, arguments: Data, access: AgentControlAccess, host: AgentControlHost) async throws -> Data {
        guard let tool = tools.first(where: { $0.name == name }) else { throw AgentControlError.unknownTool(name) }
        guard access >= tool.access else { throw AgentControlError.needsAccess(tool.access) }
        let input = try arguments.isEmpty ? Arguments() : decode(arguments)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        switch name {
        case "msgblast_status": return try encoder.encode(host.controlStatus())
        case "msgblast_agents_list":
            return try encoder.encode(host.controlAgents().filter { $0.visible || input.includeHidden == true })
        case "msgblast_comparisons_list":
            return try encoder.encode(comparisons(host, query: input.query, limit: input.limit ?? 20))
        case "msgblast_mentions":
            return try encoder.encode(mentions(host, query: input.query))
        case "msgblast_blast_wait":
            return try await encoder.encode(wait(host, after: input.after, comparisonID: input.comparisonId, timeout: input.timeoutSeconds ?? 60))
        default:
            return try encoder.encode(comparison(host, id: input.id))
        }
    }

    private struct Arguments: Decodable {
        var includeHidden: Bool?, query: String?, limit: Int?, id: String?
        var after: Int?, comparisonId: String?, timeoutSeconds: Int?
    }

    private static func decode(_ data: Data) throws -> Arguments {
        do { return try JSONDecoder().decode(Arguments.self, from: data) }
        catch { throw AgentControlError.invalidArguments(error.localizedDescription) }
    }

    private struct MentionLink: Encodable {
        var type, uri, name, description, mimeType: String
    }
    private struct MentionResult: Encodable { var items: [MentionLink] }

    /// Name or prompt, one place, for the list tool and for @-mentions.
    private static func matches(_ comparison: Comparison, query: String) -> Bool {
        query.isEmpty || comparison.prompt.localizedCaseInsensitiveContains(query) || comparison.title.localizedCaseInsensitiveContains(query)
    }

    private static func mentions(_ host: AgentControlHost, query: String?) throws -> MentionResult {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let items = try comparisons(host, query: query, limit: 20).map { summary -> MentionLink in
            let count = summary.agents.count
            return MentionLink(type: "resource_link", uri: "msgblast://comparison/\(summary.id.uuidString)",
                               name: String(summary.title.prefix(80)),
                               description: "\(formatter.string(from: summary.created)) · \(count) \(count == 1 ? "agent" : "agents")",
                               mimeType: "application/json")
        }
        return MentionResult(items: items)
    }

    private static func names(_ comparison: Comparison, agents: [AgentControlAgent]) -> [String] {
        let web = comparison.resolvedWebAgentIDs.map { id in agents.first { $0.id == id.gridID.id }?.name ?? id.provider.rawValue }
        return comparison.members.map(\.name) + web
    }

    private static func comparisons(_ host: AgentControlHost, query: String?, limit: Int) throws -> [AgentControlComparisonSummary] {
        guard (1...100).contains(limit) else { throw AgentControlError.invalidArguments("limit must be 1 to 100") }
        let agents = host.controlAgents()
        let text = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return host.controlComparisons()
            .filter { matches($0, query: text) }
            .sorted { $0.created > $1.created }
            .prefix(limit)
            .map { AgentControlComparisonSummary(id: $0.id, title: $0.title, created: $0.created, ended: $0.endedAt, agents: names($0, agents: agents)) }
    }

    private static func wait(_ host: AgentControlHost, after: Int?, comparisonID: String?, timeout: Int) async throws -> AgentControlWaitResult {
        guard (0...300).contains(timeout) else { throw AgentControlError.invalidArguments("timeoutSeconds must be 0 to 300") }
        if let after, after < 0 { throw AgentControlError.invalidArguments("after must be 0 or more") }
        let feed = host.controlEvents
        // The feed starts again at 0 when msgblast restarts, so a cursor past its end is
        // from an earlier run: read from the start rather than wait for events that already came.
        let start = after.map { $0 > feed.cursor ? 0 : $0 } ?? feed.cursor
        var comparison: UUID?
        if let comparisonID {
            guard let id = UUID(uuidString: comparisonID) else { throw AgentControlError.invalidArguments("comparisonId is not a comparison id") }
            comparison = id
        }
        let events = await feed.wait(after: start, comparisonID: comparison, timeout: .seconds(timeout))
        return AgentControlWaitResult(events: events, next: events.last?.seq ?? max(start, feed.cursor))
    }

    private static func comparison(_ host: AgentControlHost, id: String?) throws -> AgentControlComparison {
        guard let id else { throw AgentControlError.invalidArguments("id is required") }
        guard let found = host.controlComparisons().first(where: { $0.id.uuidString.caseInsensitiveCompare(id) == .orderedSame }) else {
            throw AgentControlError.notFound(id)
        }
        let submissions = Dictionary(found.members.map { ($0.name, $0.submission.rawValue) }, uniquingKeysWith: { first, _ in first })
        return AgentControlComparison(id: found.id, prompt: found.prompt, created: found.created, ended: found.endedAt,
                                      submissions: submissions, turns: host.controlTranscript(found))
    }
}
