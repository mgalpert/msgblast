import Foundation
import msgblastCore

@main enum BenchmarkSeed {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Supply a temporary AppStore directory") }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let recorder = try PerformanceRecorder(directory: directory, fixture: true); recorder.enabled = true
        let comparison = UUID().uuidString
        let alpha = PerformanceAgent(id: "fixture-alpha", name: "Synthetic Alice", connection: .website, provider: "chatgpt")
        let beta = PerformanceAgent(id: "fixture-beta", name: "Synthetic Bob", connection: .cli, provider: "codexCLI")
        let group = PerformanceRequestGroup(id: UUID().uuidString, targetAgentIDs: [alpha.id, beta.id])
        for agent in [alpha, beta] {
            let turn = try recorder.beginTurn(comparisonID: comparison, agent: agent, text: "Explain a rainbow.\n  Keep each reply separate.", scope: .shared, requestGroup: group)
            _ = try recorder.record(.dispatched, comparisonID: comparison, agent: agent, turnID: turn)
            try recorder.reply(comparisonID: comparison, agent: agent, messageID: "ack-" + agent.id, text: "I will explain it.", turnID: turn)
            try recorder.reply(comparisonID: comparison, agent: agent, messageID: "answer-" + agent.id, text: "Light bends and separates into colors.\n\n  A second reflection produces another rainbow.", turnID: turn)
            _ = try recorder.record(.completed, comparisonID: comparison, agent: agent, turnID: turn, method: "Synthetic completion fixture")
            try recorder.setFeedback(comparisonID: comparison, agentID: agent.id, messageID: "answer-" + agent.id, selection: .favorite)
        }
        let secret = try recorder.beginTurn(comparisonID: comparison, agent: alpha, text: "Synthetic private contact: alice@example.invalid /Users/synthetic/private.txt", scope: .private, requestGroup: .init(id: UUID().uuidString, targetAgentIDs: [alpha.id]))
        try recorder.reply(comparisonID: comparison, agent: alpha, messageID: "private-answer", text: "Synthetic private answer. Never included by default.", turnID: secret)
        try recorder.stop(reason: "fixture-completed")
        print("Synthetic native journal: \(recorder.events.count) events, \(recorder.replies.count) separate replies; no live connectors")
    }
}
