import Foundation
import msgblastRemoteProtocol

/// The phone's record of what it asked the Mac to do and the last result it heard.
public struct CommandRecord: Codable, Equatable, Identifiable, Sendable {
    public enum Status: String, Codable, Sendable {
        /// Sent; no result yet.
        case sending
        /// The Mac queued or is running it.
        case accepted
        case applied
        case rejected
        /// The connection ended before a result, or the Mac no longer knows it. Never resent.
        case unconfirmed
    }
    public var id: UUID
    public var kind: String
    public var conversationID: UUID?
    public var agentIDs: [String]
    public var text: String?
    public var sentAt: Date
    public var status: Status
    public var result: RemoteCommandResult?
    public var isFinal: Bool { [.applied, .rejected].contains(status) }
}

public enum CommandLedger {
    public static func record(_ command: RemoteCommand, at date: Date) -> CommandRecord {
        var conversation: UUID?, agents: [String] = [], text: String?
        switch command.action {
        case .createConversation(let t, let a, _): text = t; agents = a
        case .sendShared(let id, let t, let a, _): conversation = id; text = t; agents = a
        case .sendPrivate(let id, let agent, let t, _): conversation = id; text = t; agents = [agent]
        case .endConversation(let id), .requestReport(let id): conversation = id
        case .acknowledgeIncomplete(let agent, _), .cancelNative(let agent): agents = [agent]
        case .prepareConversation(let id, let a): conversation = id; agents = a
        default: break
        }
        return CommandRecord(id: command.clientCommandID, kind: command.action.kind, conversationID: conversation, agentIDs: agents, text: text, sentAt: date, status: .sending)
    }

    /// Applies a result, including results for queried commands after a reconnect.
    public static func apply(_ result: RemoteCommandResult, to records: inout [UUID: CommandRecord]) {
        guard var record = records[result.clientCommandID] else { return }
        switch result.outcome {
        case .accepted: if !record.isFinal { record.status = .accepted }
        case .applied: record.status = .applied
        case .rejected: record.status = result.code == .unknownCommand ? .unconfirmed : .rejected
        }
        if record.status != .accepted || record.result == nil { record.result = result }
        records[result.clientCommandID] = record
    }

    /// The connection ended: anything without a final result is unconfirmed (checked again on reconnect).
    public static func connectionLost(_ records: inout [UUID: CommandRecord]) {
        for (id, record) in records where record.status == .sending || record.status == .accepted { records[id]?.status = .unconfirmed }
    }

    /// Commands worth asking about after reconnecting.
    public static func unresolved(_ records: [UUID: CommandRecord]) -> [UUID] {
        records.values.filter { $0.status == .unconfirmed || $0.status == .sending || $0.status == .accepted }.sorted { $0.sentAt < $1.sentAt }.suffix(50).map(\.id)
    }
}
