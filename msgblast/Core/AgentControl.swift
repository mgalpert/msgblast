import Foundation

/// How much an outside agent may do. Approval in msgblast picks one level per agent.
public enum AgentControlAccess: Int, Codable, CaseIterable, Comparable, Sendable {
    case readOnly, sendToAgents, full
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    public var label: String {
        switch self { case .readOnly: "Read only"; case .sendToAgents: "Send to my agents"; case .full: "Full access" }
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
    public var agent: String, outgoing: Bool, text: String, date: Date
    public init(agent: String, outgoing: Bool, text: String, date: Date) {
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
                         summary: "Saved comparisons, newest first. query filters by prompt text.",
                         access: .readOnly, inputSchema: #"{"type":"object","properties":{"query":{"type":"string"},"limit":{"type":"integer","minimum":1,"maximum":100}}}"#),
        AgentControlTool(name: "msgblast_comparison_read", title: "Read a comparison",
                         summary: "A comparison's prompt, each agent's submission state, and the conversation so far.",
                         access: .readOnly, inputSchema: #"{"type":"object","properties":{"id":{"type":"string"}},"required":["id"]}"#)
    ]

    /// Runs one tool. Arguments and the result are JSON.
    public static func call(_ name: String, arguments: Data, access: AgentControlAccess, host: AgentControlHost) throws -> Data {
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
        default:
            return try encoder.encode(comparison(host, id: input.id))
        }
    }

    private struct Arguments: Decodable {
        var includeHidden: Bool?, query: String?, limit: Int?, id: String?
    }

    private static func decode(_ data: Data) throws -> Arguments {
        do { return try JSONDecoder().decode(Arguments.self, from: data) }
        catch { throw AgentControlError.invalidArguments(error.localizedDescription) }
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
            .filter { text.isEmpty || $0.prompt.localizedCaseInsensitiveContains(text) }
            .sorted { $0.created > $1.created }
            .prefix(limit)
            .map { AgentControlComparisonSummary(id: $0.id, title: $0.title, created: $0.created, ended: $0.endedAt, agents: names($0, agents: agents)) }
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
