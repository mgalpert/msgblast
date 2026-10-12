import AppKit
import Foundation
import msgblastCore

@main enum BenchmarkCloudWorkflow {
    @MainActor static func main() async throws {
        let _ = NSApplication.shared
        func report(_ value: String) { print(value); fflush(nil) }
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--benchmark-fixture"), index + 1 < args.count else { fatalError("Provide isolated fixture directory") }
        let root = URL(fileURLWithPath: args[index + 1]).appendingPathComponent("native-workflow-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let performance = PerformanceController(directory: root, fixture: true)
        performance.recorder!.enabled = true
        let agent = PerformanceAgent(id: "synthetic-cli", name: "Synthetic private name", connection: .cli, provider: "codexCLI")
        func turn(_ comparison: String) {
            performance.capture { recorder in
                let turn = try recorder.beginTurn(comparisonID: comparison, agent: agent, text: "Explain a rainbow.\n  Preserve indentation.", scope: .shared, requestGroup: .init(id: UUID().uuidString, targetAgentIDs: [agent.id]))
                _ = try recorder.record(.dispatched, comparisonID: comparison, agent: agent, turnID: turn)
                try recorder.reply(comparisonID: comparison, agent: agent, messageID: "answer-\(comparison)", text: "Synthetic answer\n  Two lines.", turnID: turn)
                _ = try recorder.record(.completed, comparisonID: comparison, agent: agent, turnID: turn)
                try recorder.stop(reason: "completed")
            }
        }
        let priorID = "prior-" + UUID().uuidString, futureID = "future-" + UUID().uuidString
        turn(priorID)
        var controller = BenchmarkController(directory: root, demo: true)
        controller.attach(performance: performance)
        await controller.signIn()
        precondition(controller.account.account != nil, controller.account.errorMessage ?? "Sign-in fixture failed")
        precondition(controller.lineages.isEmpty && controller.paused && !controller.futureSync)
        report("PASS: synthetic PKCE/code exchange verified by actual loopback Worker; sign-in uploaded no recordings")
        let projection = try ComparisonPublicationBuilder.build(events: performance.events, comparisonID: priorID)
        await controller.publish(projection, comparisonID: priorID, owner: controller.account.account!.accountID, accountGeneration: controller.account.generation)
        precondition(controller.error == nil, controller.error ?? "Publication failed")
        precondition(controller.lineages.isEmpty && controller.paused)
        let link = controller.publicationLinks.first!
        let (page, response) = try await URLSession.shared.data(from: link.url)
        precondition((response as! HTTPURLResponse).statusCode == 200)
        precondition(String(decoding: page, as: UTF8.self).contains("Shared comparison"))
        report("PASS: exact redacted publication read anonymously with private sync off")
        controller.setFutureSync(true)
        turn(futureID)
        await wait { controller.lineages.first(where: { $0.comparisonID == futureID })?.finalized == true }
        precondition(controller.error == nil, controller.error ?? "Automatic future sync failed")
        precondition(!controller.lineages.contains { $0.comparisonID == priorID })
        let first = controller.lineages.first!
        report("PASS: future recording uploaded automatically; existing local prefix was not backfilled")
        await controller.contribute(BenchmarkContributionApproval(lineage: first, owner: first.owner)!)
        precondition(controller.error == nil, controller.error ?? "First snapshot contribution failed")
        precondition(controller.contributionSummaries.first { $0.session == first.sessionID }?.revision == 1)
        controller.shutdown()
        controller = BenchmarkController(directory: root, demo: true)
        controller.attach(performance: performance)
        await controller.restore()
        await controller.signIn()
        precondition(controller.lineages.first!.snapshotID == first.snapshotID)
        precondition(controller.publicationLinks.first?.url == link.url)
        precondition(controller.futureSync && !controller.paused)
        report("PASS: relaunch restored exact upload head, saved capability and owner-bound ongoing consent; synthetic credentials signed in anew")
        controller.pause()
        performance.capture { try $0.setFeedback(comparisonID: futureID, agentID: agent.id, messageID: "answer-\(futureID)", selection: .favorite) }
        try await Task.sleep(for: .seconds(3))
        precondition(controller.lineages.first!.revision == first.revision)
        await controller.resumeSaved()
        await wait { controller.lineages.first?.revision == 2 && controller.lineages.first?.finalized == true }
        precondition(controller.lineages.first!.finalizedSequenceEnd > first.finalizedSequenceEnd)
        let afterPage = try await URLSession.shared.data(from: link.url).0
        precondition(afterPage == page)
        report("PASS: pause stopped transmission; resume created explicit private revision; earlier publication bytes unchanged")
        let current = controller.lineages.first!
        let currentSnapshot = current.snapshotID!
        let oldValidation = try await controller.client!.validation(sessionID: first.sessionID!, snapshotID: first.snapshotID!, owner: first.owner)
        let oldJSON = try JSONSerialization.jsonObject(with: oldValidation) as! [String: Any]
        precondition(oldJSON["completeness"] != nil)
        await controller.refreshRecords()
        precondition(controller.contributionSummaries.first { $0.session == current.sessionID }?.snapshotID == first.snapshotID, "Private continuation must not move the chosen contribution")
        await controller.contribute(BenchmarkContributionApproval(lineage: current, owner: current.owner)!)
        precondition(controller.contributionSummaries.first { $0.session == current.sessionID }?.revision == 2)
        await controller.contribute(BenchmarkContributionApproval(lineage: current, owner: current.owner)!)
        precondition(controller.contributionSummaries.first { $0.session == current.sessionID }?.revision == 2, "Exact selected snapshot retry must retain revision")
        precondition(controller.error == nil, controller.error ?? "Contribution failed")
        precondition(controller.contributionHistory.contains(currentSnapshot))
        precondition(controller.acceptedComparisons == 0, "Synthetic fixture accepted comparisons must be explicitly zero")
        precondition(controller.contributionHistory.contains("ineligible"), "Synthetic fixture must not become accepted benchmark credit")
        report("PASS: contribution bound chosen snapshot; fixture ineligible; old snapshot validation remains accessible")
        await controller.withdraw(current)
        precondition(controller.contributionHistory.contains("withdrawn"))
        await controller.contribute(BenchmarkContributionApproval(lineage: current, owner: current.owner)!)
        precondition(controller.contributionSummaries.first { $0.session == current.sessionID }?.revision == 3, "Fresh choice after withdrawal must advance internally")
        await controller.withdraw(current)
        report("PASS: contribution selection internally advanced snapshot1 to snapshot2; exact retry stayed at2; fresh withdrawn choice advanced to3")
        // A link made with sync off must still be associated if this comparison
        // is explicitly uploaded later. Sharing itself registered no raw session.
        await controller.upload(events: performance.events, comparisonID: priorID, context: "unknown")
        precondition(controller.error == nil, controller.error ?? "Explicit earlier upload failed")
        let earlier = controller.lineages.first { $0.comparisonID == priorID }!
        await controller.delete(earlier)
        let (_, deletedEarlier) = try await URLSession.shared.data(from: link.url)
        precondition((deletedEarlier as! HTTPURLResponse).statusCode == 404)
        precondition(!controller.publicationLinks.contains { $0.id == link.id })
        let laterProjection = try ComparisonPublicationBuilder.build(events: performance.events, comparisonID: futureID)
        await controller.publish(laterProjection, comparisonID: futureID, owner: controller.account.account!.accountID, accountGeneration: controller.account.generation)
        precondition(controller.error == nil, controller.error ?? "Associated publication failed")
        let laterLink = controller.publicationLinks.first!
        report("PASS: publish-before-upload association revoked through later private record deletion; no raw upload on initial sharing")

        let (_, revoked) = try await URLSession.shared.data(from: link.url)
        precondition((revoked as! HTTPURLResponse).statusCode == 404)
        await controller.delete(current)
        let (_, deletedLater) = try await URLSession.shared.data(from: laterLink.url)
        precondition((deletedLater as! HTTPURLResponse).statusCode == 404)
        precondition(controller.publicationLinks.isEmpty)
        report("PASS: upload-before-publish association revoked and removed from saved local links")
        precondition(controller.lineages.isEmpty)
        try await Task.sleep(for: .seconds(3))
        precondition(controller.lineages.isEmpty, "Deleted comparison must never queue again")
        report("PASS: withdrawal, link revocation and private cloud deletion used actual Worker routes")
        controller.signOut(); precondition(controller.account.account == nil && controller.paused)
        report("PASS: sign-out stops private sync; no live identity/provider, Messages or Contacts actions")
    }
    @MainActor static func wait(_ condition: () -> Bool) async {
        for _ in 0..<100 { if condition() { return }; try? await Task.sleep(for: .milliseconds(100)) }
        preconditionFailure("Timed out waiting for actual native/Worker workflow")
    }
}
