import AppKit
import msgblastCore

@main struct SideChatModelCheck {
    @MainActor static func waitUntil(_ check: () -> Bool) async throws {
        for _ in 0..<100 { if check() { return }; try await Task.sleep(for: .milliseconds(100)) }
        preconditionFailure("Model fixture did not reach expected state")
    }
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let model = AppModel()
        precondition(model.demo && model.local.url.path.contains("UIFixture"))
        model.coordinator = WindowCoordinator(model: model)
        let recipient = model.state.agents[0]
        let first = await model.prepareWebComparison("First comparison", recipientIDs: [recipient.id], providers: WebProvider.allCases)!
        let muse = model.webAgents.sessions.first { $0.provider == .muse }!
        precondition(muse.fixture)
        model.webAgents.sessions.forEach { $0.connect() }
        try await waitUntil { model.webAgents.sessions.allSatisfy { $0.snapshot.ready } }
        let firstResults = await WebAgents.send("First comparison", to: model.webAgents.sessions, comparisonID: first)
        precondition(firstResults.values.allSatisfy { $0.status == .observed })
        let firstNativeSessions = Dictionary(uniqueKeysWithValues: model.webAgents.sessions.compactMap { session in session.state.localSessionIDs[first.uuidString].map { (session.provider, $0) } })
        await model.submit(first, retry: false)
        let second = await model.prepareWebComparison("Second comparison", recipientIDs: [], providers: WebProvider.allCases)!
        let secondResults = await WebAgents.send("Second comparison", to: model.webAgents.sessions, comparisonID: second)
        precondition(secondResults.values.allSatisfy { $0.status == .observed })
        for session in model.webAgents.sessions {
            if session.provider.personalAgentProvider != nil {
                precondition(firstNativeSessions[session.provider] != session.state.localSessionIDs[second.uuidString])
            } else { precondition(firstResults[session.provider]?.conversationURL != secondResults[session.provider]?.conversationURL) }
        }
        model.coordinator?.open(first)
        try await waitUntil { model.webAgents.sessions.allSatisfy { session in
            if session.provider.personalAgentProvider != nil {
                return session.state.comparisonID == first && session.snapshot.messages.first?.text == "First comparison" && session.state.localSessionIDs[first.uuidString] == firstNativeSessions[session.provider]
            }
            return session.webView.url == firstResults[session.provider]?.conversationURL
        } }
        precondition(model.state.selection == [recipient.id])
        precondition(model.webAgents.selected.map(\.provider) == WebProvider.allCases)
        precondition(model.webAgents.comparisonID == first)
        precondition(model.comparison(first)?.members.first?.submission == .submitted)
        let attachment = try model.local.stage(Data("fixture attachment".utf8), filename: "sidechat-followup.txt")
        for text in ["", "Text with attachment"] {
            model.setAttachmentDraft([attachment], comparisonID: first)
            model.state.comparisons[model.index(first)!].allDraft = text
            await model.followUp(first, recipients: [recipient.id])
            let followup = model.comparison(first)!.followUps.last!
            precondition(followup.states[recipient.id.uuidString] == .submitted)
            precondition(followup.payloads?[recipient.id.uuidString]?.parts.contains { $0.attachment?.id == attachment.id } == true)
            precondition(model.attachmentDraft(comparisonID: first).isEmpty)
        }
        let beforeRetry = muse.state.attempts.count
        let failed = FollowUp(text: "Controlled failed follow-up", memberIDs: [recipient.id])
        model.state.comparisons[model.index(first)!].followUps.append(failed)
        let k = model.state.comparisons[model.index(first)!].followUps.count - 1
        model.state.comparisons[model.index(first)!].followUps[k].states[recipient.id.uuidString] = .failed
        await model.followUp(first, retry: failed.id)
        precondition(model.comparison(first)?.followUps.last?.states[recipient.id.uuidString] == .submitted)
        precondition(muse.state.attempts.count == beforeRetry)
        print("PASS: attachment-only and text-plus-attachment native follow-ups submit their comparison drafts; native retry does not resend Muse. Controlled local fixture inputs.")
        print("PASS: actual AppModel + WindowCoordinator restore comparison ID, native recipient, provider selection, saved Muse/Grok URLs and native ChatGPT/Claude sessions. All sends use local fixtures.")
    }
}
