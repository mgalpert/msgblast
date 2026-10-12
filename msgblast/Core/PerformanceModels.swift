import Foundation
import CryptoKit

public enum PerformanceConnection: String, Codable, Sendable { case website, messages, cli, grokBot }
public enum PerformanceScope: String, Codable, Sendable { case shared, `private`, unknown }
public enum PerformanceFeedback: String, Codable, Sendable { case favorite, negative, unmarked }
public enum PerformanceEventKind: String, Codable, Sendable {
    case segmentStarted, turnStarted, dispatched, submitted, replyObserved, completed, outcome, feedback, gap, observationState, segmentEnded
}
public struct PerformanceRequestGroup: Codable, Equatable, Sendable {
    public var id: String
    public var targetAgentIDs: [String]
    public init(id: String, targetAgentIDs: [String]) {
        self.id = id; self.targetAgentIDs = Array(Set(targetAgentIDs)).sorted()
    }
}
public struct PerformanceAgent: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var connection: PerformanceConnection
    public var provider: String?
    public var model: String?
    public init(id: String, name: String, connection: PerformanceConnection, provider: String? = nil, model: String? = nil) {
        self.id = id; self.name = name; self.connection = connection; self.provider = provider; self.model = model
    }
}
public struct PerformanceStamp: Codable, Equatable, Sendable {
    private static let processClock = UUID().uuidString
    public var clockID: String
    public var monotonicMS: Int64
    public var wallMS: Int64
    public init(clockID: String, monotonicMS: Int64, wallMS: Int64) {
        self.clockID = clockID; self.monotonicMS = monotonicMS; self.wallMS = wallMS
    }
    public static var now: Self {
        .init(clockID: processClock, monotonicMS: Int64(ProcessInfo.processInfo.systemUptime * 1000), wallMS: Int64(Date().timeIntervalSince1970 * 1000))
    }
}
public struct PerformanceEvent: Codable, Equatable, Identifiable, Sendable {
    public var schemaVersion = 1
    public var id = UUID().uuidString
    public var sequence: Int
    public var comparisonID: String
    public var segmentID: String
    public var kind: PerformanceEventKind
    public var stamp: PerformanceStamp
    public var fixture: Bool
    public var previousHash: String?
    public var agent: PerformanceAgent?
    public var turnID: String?
    public var turnPosition: Int?
    public var requestGroupID: String?
    public var targetAgentIDs: [String]?
    public var scope: PerformanceScope?
    public var messageID: String?
    public var text: String?
    public var sourceMS: Int64?
    public var method: String?
    public var reason: String?
    public var selection: PerformanceFeedback?
}
public struct PerformanceUploadChunk: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var id: String
    public var sessionID: String
    public var sequenceStart: Int
    public var sequenceEnd: Int
    public var previousHash: String?
    public var events: [PerformanceEvent]
    public var artifacts: [String] = []
    public init(id: String, sessionID: String, sequenceStart: Int, previousHash: String? = nil, events: [PerformanceEvent]) {
        self.id = id; self.sessionID = sessionID; self.sequenceStart = sequenceStart
        self.sequenceEnd = sequenceStart + events.count - 1; self.previousHash = previousHash; self.events = events
    }
}
public enum PerformanceCanonical {
    public static func bytes<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    public static func hash(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
public struct PerformanceReply: Identifiable, Equatable, Sendable {
    public var id: String { segmentID + ":" + agent.id + ":" + messageID }
    public var comparisonID: String
    public var segmentID: String
    public var agent: PerformanceAgent
    public var messageID: String
    public var text: String
    public var turnID: String?
    public var scope: PerformanceScope
    public var feedback: PerformanceFeedback = .unmarked
}
