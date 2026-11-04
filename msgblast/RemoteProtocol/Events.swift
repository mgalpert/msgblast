import Foundation

/// One change, numbered by the Mac's monotonic `seq`.
public struct RemoteEvent: Codable, Hashable, Sendable {
    public var seq: UInt64
    public var change: RemoteChange
    public init(seq: UInt64, change: RemoteChange) { self.seq = seq; self.change = change }
}

public enum RemoteChange: Codable, Hashable, Sendable {
    case macStatus(MacStatus)
    case grid(RemoteGrid)
    case agentUpsert(AgentAvailability)
    case agentRemove(id: String)
    case conversationUpsert(RemoteConversation)
    case conversationRemove(id: UUID)
    case turnUpsert(RemoteTurn)
    case turnRemove(id: String)
    case attemptUpsert(RemoteAttempt)
    case attemptRemove(id: String)
    /// A change kind this build does not know. Clients should request a snapshot.
    case unknown(kind: String)

    public var kind: String {
        switch self {
        case .macStatus: "macStatus"; case .grid: "grid"
        case .agentUpsert: "agentUpsert"; case .agentRemove: "agentRemove"
        case .conversationUpsert: "conversationUpsert"; case .conversationRemove: "conversationRemove"
        case .turnUpsert: "turnUpsert"; case .turnRemove: "turnRemove"
        case .attemptUpsert: "attemptUpsert"; case .attemptRemove: "attemptRemove"
        case .unknown(let kind): kind
        }
    }
    private enum CodingKeys: String, CodingKey { case kind, payload, id }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "macStatus": self = .macStatus(try c.decode(MacStatus.self, forKey: .payload))
        case "grid": self = .grid(try c.decode(RemoteGrid.self, forKey: .payload))
        case "agentUpsert": self = .agentUpsert(try c.decode(AgentAvailability.self, forKey: .payload))
        case "agentRemove": self = .agentRemove(id: try c.decode(String.self, forKey: .id))
        case "conversationUpsert": self = .conversationUpsert(try c.decode(RemoteConversation.self, forKey: .payload))
        case "conversationRemove": self = .conversationRemove(id: try c.decode(UUID.self, forKey: .id))
        case "turnUpsert": self = .turnUpsert(try c.decode(RemoteTurn.self, forKey: .payload))
        case "turnRemove": self = .turnRemove(id: try c.decode(String.self, forKey: .id))
        case "attemptUpsert": self = .attemptUpsert(try c.decode(RemoteAttempt.self, forKey: .payload))
        case "attemptRemove": self = .attemptRemove(id: try c.decode(String.self, forKey: .id))
        default: self = .unknown(kind: kind)
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        switch self {
        case .macStatus(let value): try c.encode(value, forKey: .payload)
        case .grid(let value): try c.encode(value, forKey: .payload)
        case .agentUpsert(let value): try c.encode(value, forKey: .payload)
        case .agentRemove(let id): try c.encode(id, forKey: .id)
        case .conversationUpsert(let value): try c.encode(value, forKey: .payload)
        case .conversationRemove(let id): try c.encode(id, forKey: .id)
        case .turnUpsert(let value): try c.encode(value, forKey: .payload)
        case .turnRemove(let id): try c.encode(id, forKey: .id)
        case .attemptUpsert(let value): try c.encode(value, forKey: .payload)
        case .attemptRemove(let id): try c.encode(id, forKey: .id)
        case .unknown: break
        }
    }
}
