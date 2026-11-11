import CryptoKit
import Foundation
import msgblastRemoteProtocol

/// Send tools for outside agents. Each call becomes a command for the same executor the
/// iPhone controller uses, so it gets the same checks (a locked or busy Mac, each agent's
/// readiness), runs one at a time, and is never retried. A `requestId` makes a call safe to
/// repeat while msgblast runs: the same id returns the first result instead of sending again.
public enum AgentControlSend {
    public static let names: Set<String> = ["msgblast_blast_start", "msgblast_blast_follow_up", "msgblast_agent_message", "msgblast_comparison_end"]
    public static let maximumTextLength = 50_000

    static let requestIDSummary = "requestId: your own id for this call, such as a UUID. While msgblast keeps running, calling again with the same requestId returns the first result instead of sending again (it remembers its last 1,000 sends). After a timeout or a restart, ask msgblast_request_status and check the comparison before repeating."

    public static let tools: [AgentControlTool] = [
        AgentControlTool(name: "msgblast_blast_start", title: "Start a blast",
                         summary: "Sends one message to several agents at once and starts a comparison. agents are ids from msgblast_agents_list. Returns the comparison id and each agent's send status; replies arrive later through msgblast_blast_wait. \(requestIDSummary)",
                         access: .full, inputSchema: #"{"type":"object","properties":{"text":{"type":"string","minLength":1},"agents":{"type":"array","items":{"type":"string"},"minItems":1},"requestId":{"type":"string","maxLength":200}},"required":["text","agents"]}"#),
        AgentControlTool(name: "msgblast_blast_follow_up", title: "Follow up",
                         summary: "Sends a follow-up in a comparison to the listed agents, or to every agent in it that takes shared messages when agents is left out. \(requestIDSummary)",
                         access: .full, inputSchema: #"{"type":"object","properties":{"comparisonId":{"type":"string"},"text":{"type":"string","minLength":1},"agents":{"type":"array","items":{"type":"string"}},"requestId":{"type":"string","maxLength":200}},"required":["comparisonId","text"]}"#),
        AgentControlTool(name: "msgblast_agent_message", title: "Message one agent",
                         summary: "Sends a private message to one agent, inside a comparison when comparisonId is given or as a new one-agent comparison. \(requestIDSummary)",
                         access: .full, inputSchema: #"{"type":"object","properties":{"agent":{"type":"string"},"text":{"type":"string","minLength":1},"comparisonId":{"type":"string"},"requestId":{"type":"string","maxLength":200}},"required":["agent","text"]}"#),
        AgentControlTool(name: "msgblast_comparison_end", title: "End a comparison",
                         summary: "Ends a comparison so nothing more is sent in it. \(requestIDSummary)",
                         access: .full, inputSchema: #"{"type":"object","properties":{"comparisonId":{"type":"string"},"requestId":{"type":"string","maxLength":200}},"required":["comparisonId"]}"#),
        AgentControlTool(name: "msgblast_request_status", title: "Check a request",
                         summary: "The result of an earlier send tool call, by its requestId. Never sends anything. outcome unknown means msgblast has no record of it, for example after a restart: check the comparison before sending again.",
                         access: .readOnly, inputSchema: #"{"type":"object","properties":{"requestId":{"type":"string","maxLength":200}},"required":["requestId"]}"#)
    ]

    /// The executor's agent id for an id from `msgblast_agents_list`. Nil when it can't take sends.
    public static func remoteID(_ agentID: String) -> String? {
        if agentID.hasPrefix("messages:") { return UUID(uuidString: String(agentID.dropFirst("messages:".count))) == nil ? nil : agentID }
        if agentID.hasPrefix("web-instance:") {
            let id = String(agentID.dropFirst("web-instance:".count))
            return id.isEmpty ? nil : id
        }
        if agentID.hasPrefix("web:") { return WebProvider(rawValue: String(agentID.dropFirst("web:".count))).map { WebAgentID(provider: $0).id } }
        return nil
    }

    /// The `msgblast_agents_list` id for an executor agent id.
    public static func listID(_ remoteID: String) -> String {
        if remoteID.hasPrefix("messages:") { return remoteID }
        return remoteID.contains(":") ? "web-instance:\(remoteID)" : "web:\(remoteID)"
    }

    /// The executor's command id for a `requestId`, kept apart per agent name so two agents
    /// that pick the same requestId never see each other's results.
    public static func commandID(client: String, requestID: String) -> UUID {
        let digest = Array(SHA256.hash(data: Data("msgblast-agent-request\u{0}\(client)\u{0}\(requestID)".utf8)))
        var b = Array(digest.prefix(16))
        b[6] = (b[6] & 0x0F) | 0x50
        b[8] = (b[8] & 0x3F) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    public struct Input: Equatable, Sendable {
        public var text: String?, agents: [String]?, agent: String?, comparisonID: String?
        public init(text: String? = nil, agents: [String]? = nil, agent: String? = nil, comparisonID: String? = nil) {
            self.text = text; self.agents = agents; self.agent = agent; self.comparisonID = comparisonID
        }
    }

    /// The executor command for one send tool call. Throws for arguments the executor would refuse anyway.
    public static func command(_ tool: String, _ input: Input, id: UUID) throws -> RemoteCommand {
        let action: RemoteAction
        switch tool {
        case "msgblast_blast_start":
            guard let agents = input.agents, !agents.isEmpty else { throw AgentControlError.invalidArguments("agents is required") }
            action = .createConversation(text: try text(input), agentIDs: try agents.map(sendable), attachmentIDs: [])
        case "msgblast_blast_follow_up":
            action = .sendShared(conversationID: try comparison(input), text: try text(input), agentIDs: try (input.agents ?? []).map(sendable), attachmentIDs: [])
        case "msgblast_agent_message":
            guard let one = input.agent else { throw AgentControlError.invalidArguments("agent is required") }
            let conversation = try input.comparisonID.map { _ in try comparison(input) }
            action = .sendPrivate(conversationID: conversation, agentID: try sendable(one), text: try text(input), attachmentIDs: [])
        case "msgblast_comparison_end":
            action = .endConversation(conversationID: try comparison(input))
        default:
            throw AgentControlError.unknownTool(tool)
        }
        return RemoteCommand(clientCommandID: id, action: action)
    }

    private static func comparison(_ input: Input) throws -> UUID {
        guard let raw = input.comparisonID else { throw AgentControlError.invalidArguments("comparisonId is required") }
        guard let value = UUID(uuidString: raw) else { throw AgentControlError.invalidArguments("comparisonId is not a comparison id") }
        return value
    }

    private static func text(_ input: Input) throws -> String {
        guard let text = input.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AgentControlError.invalidArguments("text is required") }
        guard text.count <= maximumTextLength else { throw AgentControlError.invalidArguments("text is limited to \(maximumTextLength) characters") }
        return text
    }

    private static func sendable(_ id: String) throws -> String {
        guard let remote = remoteID(id) else {
            throw AgentControlError.invalidArguments("\(id) is not an agent msgblast can send to. Use ids from msgblast_agents_list.")
        }
        return remote
    }

    /// What a send tool returns. A refusal throws instead, so MCP clients see an error.
    public static func result(_ result: RemoteCommandResult, requestID: String, agents: [AgentControlAgent], refusalThrows: Bool) throws -> AgentControlSendResult {
        let names = Dictionary(agents.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let ids = Set(result.agentStatuses.keys).union(result.agentReasons.keys).sorted()
        let rows = ids.map { remote -> AgentControlSendResult.Agent in
            let id = listID(remote)
            return .init(id: id, name: names[id] ?? remote, status: result.agentStatuses[remote]?.rawValue, reason: result.agentReasons[remote])
        }
        let outcome: String
        switch result.outcome {
        case .applied: outcome = "done"
        case .accepted: outcome = "running"
        case .rejected:
            if result.code == .unknownCommand { outcome = "unknown" } else {
                if refusalThrows {
                    let reasons = rows.compactMap { row in row.reason.map { "\(row.name): \($0)" } }
                    let message = result.message ?? "msgblast did not send it"
                    let code = result.code.map { " (\($0.rawValue))" } ?? ""
                    throw AgentControlError.refused(([message] + reasons).joined(separator: ". ") + ". Nothing was sent\(code). "
                        + "A repeat with the same requestId gets this same answer, so use a new requestId to try again.")
                }
                outcome = "refused"
            }
        }
        return AgentControlSendResult(outcome: outcome, requestId: requestID, replayed: result.replayed, comparisonId: result.conversationID,
                                      code: result.code?.rawValue, message: result.message, agents: rows)
    }
}

public struct AgentControlSendResult: Codable, Equatable, Sendable {
    public struct Agent: Codable, Equatable, Sendable {
        public var id: String, name: String, status: String?, reason: String?
    }
    /// done: msgblast ran it (for a send, it submitted to each agent; replies come as events).
    /// running: still going. refused: nothing was sent. unknown: msgblast has no record of it.
    public var outcome: String, requestId: String, replayed: Bool, comparisonId: UUID?
    public var code: String?, message: String?, agents: [Agent]
}

/// How often one agent name may call the send tools: 6 a minute and 60 an hour. A repeat of
/// a requestId msgblast already knows does not count.
public struct AgentControlSendLimit: Sendable {
    public static let windows: [(seconds: TimeInterval, count: Int)] = [(60, 6), (3600, 60)]
    private var calls: [String: [Date]] = [:]
    public init() {}

    public mutating func allow(_ client: String, now: Date = Date()) -> Bool {
        let longest = Self.windows.map(\.seconds).max() ?? 0
        let recent = (calls[client] ?? []).filter { now.timeIntervalSince($0) < longest }
        calls[client] = recent
        for window in Self.windows where recent.filter({ now.timeIntervalSince($0) < window.seconds }).count >= window.count { return false }
        calls[client] = recent + [now]
        return true
    }
}
