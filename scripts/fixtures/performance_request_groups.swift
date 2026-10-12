// Emits a portable synthetic upload through the real native recorder and codec.
import Foundation
import msgblastCore

@main struct PerformanceRequestGroupFixture {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("msgblast-group-contract-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = try PerformanceRecorder(directory: directory, fixture: true); recorder.enabled = true
        let comparison = "synthetic-group-comparison"
        let agents = [PerformanceAgent(id: "web-a", name: "Synthetic Web", connection: .website, provider: "chatgpt"),
            PerformanceAgent(id: "cli-b", name: "Synthetic CLI", connection: .cli, provider: "codexCLI"),
            PerformanceAgent(id: "messages-c", name: "Synthetic Messages", connection: .messages),
            PerformanceAgent(id: "bot-d", name: "Synthetic Bot", connection: .grokBot, provider: "grokbot")]
        let initial = PerformanceRequestGroup(id: comparison, targetAgentIDs: agents.map(\.id))
        let privateGroup = PerformanceRequestGroup(id: "synthetic-private-action", targetAgentIDs: [agents[1].id])
        let repeated = PerformanceRequestGroup(id: "synthetic-shared-follow-up", targetAgentIDs: agents.map(\.id))
        let subset = PerformanceRequestGroup(id: "synthetic-targeted-follow-up", targetAgentIDs: [agents[0].id, agents[2].id])
        var tick: Int64 = 0
        func stamp() -> PerformanceStamp { tick += 100; return .init(clockID: "synthetic-group-clock", monotonicMS: tick, wallMS: 1791792000000 + tick) }
        func record(_ group: PerformanceRequestGroup, agents targets: [PerformanceAgent], scope: PerformanceScope) throws {
            for agent in targets {
                let turn = try recorder.beginTurn(comparisonID: comparison, agent: agent, text: "Repeated synthetic request — same text, distinct action", scope: scope, requestGroup: group, at: stamp())
                _ = try recorder.record(.dispatched, comparisonID: comparison, agent: agent, turnID: turn, at: stamp())
                try recorder.reply(comparisonID: comparison, agent: agent, messageID: group.id + ":" + agent.id + ":reply", text: "Synthetic answer.\n    Indentation remains intact.", turnID: turn, method: agent.connection == .website ? "web-dom-observer; native attributed receipt" : agent.connection == .cli ? "cli-final-output; streaming unavailable" : agent.connection == .grokBot ? "bot-authenticated-callback; streaming unavailable" : "messages-poll; completion unsupported", at: stamp())
                if agent.connection != .messages { _ = try recorder.record(.completed, comparisonID: comparison, agent: agent, turnID: turn, method: "synthetic supported answer completion", at: stamp()) }
            }
        }
        try record(initial, agents: agents, scope: .shared)
        try record(privateGroup, agents: [agents[1]], scope: .private)
        try record(repeated, agents: agents, scope: .shared)
        try record(subset, agents: [agents[0], agents[2]], scope: .private)
        let manual = try recorder.beginTurn(comparisonID: comparison, agent: agents[0], text: "Manual unaligned request", scope: .unknown, at: stamp())
        try recorder.reply(comparisonID: comparison, agent: agents[0], messageID: "manual-unaligned-reply", text: "No request group or retroactive dispatch was observed.", turnID: manual, method: "web-manual-observation; group unknown", at: stamp())
        let chunk = PerformanceUploadChunk(id: "synthetic-native-group-chunk", sessionID: comparison, sequenceStart: 1, events: recorder.events)
        let bytes = try PerformanceCanonical.bytes(chunk)
        let destination = URL(fileURLWithPath: CommandLine.arguments[1])
        try bytes.write(to: destination)
        try (PerformanceCanonical.hash(bytes) + "\n").write(to: destination.deletingPathExtension().appendingPathExtension("sha256"), atomically: true, encoding: .utf8)
        print("Native-produced request-group fixture: \(bytes.count) bytes, \(chunk.events.count) events; SHA-256 \(PerformanceCanonical.hash(bytes))")
    }
}
