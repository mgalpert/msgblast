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
        if let change = try Self.decodePayloadChange(kind, from: c) {
            self = change
        } else {
            self = try Self.decodeRemovalChange(kind, from: c)
        }
    }
    /// Changes that carry a `payload`; nil for any other kind.
    private static func decodePayloadChange(_ kind: String, from c: KeyedDecodingContainer<CodingKeys>) throws -> RemoteChange? {
        switch kind {
        case "macStatus": return .macStatus(try c.decode(MacStatus.self, forKey: .payload))
        case "grid": return .grid(try c.decode(RemoteGrid.self, forKey: .payload))
        case "agentUpsert": return .agentUpsert(try c.decode(AgentAvailability.self, forKey: .payload))
        case "conversationUpsert": return .conversationUpsert(try c.decode(RemoteConversation.self, forKey: .payload))
        case "turnUpsert": return .turnUpsert(try c.decode(RemoteTurn.self, forKey: .payload))
        case "attemptUpsert": return .attemptUpsert(try c.decode(RemoteAttempt.self, forKey: .payload))
        default: return nil
        }
    }
    /// Removals by `id`; any other kind is kept as `unknown`.
    private static func decodeRemovalChange(_ kind: String, from c: KeyedDecodingContainer<CodingKeys>) throws -> RemoteChange {
        switch kind {
        case "agentRemove": return .agentRemove(id: try c.decode(String.self, forKey: .id))
        case "conversationRemove": return .conversationRemove(id: try c.decode(UUID.self, forKey: .id))
        case "turnRemove": return .turnRemove(id: try c.decode(String.self, forKey: .id))
        case "attemptRemove": return .attemptRemove(id: try c.decode(String.self, forKey: .id))
        default: return .unknown(kind: kind)
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        switch self {
        case .macStatus, .grid, .agentUpsert, .conversationUpsert, .turnUpsert, .attemptUpsert: try encodePayload(into: &c)
        case .agentRemove, .conversationRemove, .turnRemove, .attemptRemove: try encodeRemovedID(into: &c)
        case .unknown: break
        }
    }
    private func encodePayload(into c: inout KeyedEncodingContainer<CodingKeys>) throws {
        switch self {
        case .macStatus(let value): try c.encode(value, forKey: .payload)
        case .grid(let value): try c.encode(value, forKey: .payload)
        case .agentUpsert(let value): try c.encode(value, forKey: .payload)
        case .conversationUpsert(let value): try c.encode(value, forKey: .payload)
        case .turnUpsert(let value): try c.encode(value, forKey: .payload)
        case .attemptUpsert(let value): try c.encode(value, forKey: .payload)
        default: break
        }
    }
    private func encodeRemovedID(into c: inout KeyedEncodingContainer<CodingKeys>) throws {
        switch self {
        case .agentRemove(let id): try c.encode(id, forKey: .id)
        case .conversationRemove(let id): try c.encode(id, forKey: .id)
        case .turnRemove(let id): try c.encode(id, forKey: .id)
        case .attemptRemove(let id): try c.encode(id, forKey: .id)
        default: break
        }
    }
}
