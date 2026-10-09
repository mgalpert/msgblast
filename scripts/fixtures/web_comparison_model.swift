import AppKit
import SwiftUI
import msgblastCore

@MainActor private final class DelayedBroadcastGate {
    var messagesFinished = false
}

@main struct SideChatModelCheck {
    @MainActor static func waitUntil(_ check: () -> Bool) async throws {
        for _ in 0..<100 { if check() { return }; try await Task.sleep(for: .milliseconds(100)) }
        preconditionFailure("Model fixture did not reach expected state")
    }
    @MainActor static func privateEditor(in view: NSView) -> AttachmentTextView? {
        if let editor = view as? AttachmentTextView { return editor }
        for child in view.subviews { if let editor = privateEditor(in: child) { return editor } }
        return nil
    }
    @MainActor static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        Task { @MainActor in
            do { try await runChecks() }
            catch { fatalError("Isolated model fixture failed: \(error)") }
            application.stop(nil)
            let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)!
            application.postEvent(wake, atStart: true)
        }
        application.run()
    }
    @MainActor static func runChecks() async throws {
        _ = NSApplication.shared
        let migrationStore = LocalStore(demo: true, isolated: true)
        let migrationDirectory = migrationStore.url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: migrationDirectory) }
        var legacy = AppState()
        for providers in [[WebProvider.chatgpt], [.claude], []] {
            var comparison = Comparison(prompt: "Migration fixture", members: [])
            comparison.webProviders = providers; comparison.webProviderIdentityVersion = nil
            legacy.comparisons.append(comparison)
        }
        try migrationStore.save(legacy)
        let corrupt = Data("corrupt referenced ChatGPT file".utf8)
        let corruptURL = migrationDirectory.appendingPathComponent(WebProvider.chatgpt.storageFilename)
        try corrupt.write(to: corruptURL)
        var loaded = try migrationStore.load()
        precondition(loaded.comparisons.count == 3)
        precondition(loaded.comparisons[0].webProviderIdentityVersion == nil)
        precondition(loaded.comparisons[1...].allSatisfy { $0.webProviderIdentityVersion == 2 })
        try migrationStore.save(loaded)
        let isolated = WebAgents(directory: migrationDirectory, fixture: true)
        precondition(isolated.sessions.first { $0.provider == .chatgpt }!.error != nil)
        precondition(isolated.sessions.first { $0.provider == .claude }!.error == nil)
        let preservedCorrupt = try Data(contentsOf: corruptURL)
        precondition(preservedCorrupt == corrupt)
        var repaired = WebWorkspaceState(); repaired.providerIdentityVersion = 1
        try JSONEncoder().encode(repaired).write(to: corruptURL)
        loaded = try migrationStore.load()
        precondition(loaded.comparisons.allSatisfy { $0.webProviderIdentityVersion == 2 })
        print("PASS: LocalStore loads healthy comparisons despite a referenced corrupt provider, preserves that file, and retries successfully after repair.")
        let model = AppModel()
        precondition(model.demo && model.local.url.path.contains("UIFixture"))
        model.coordinator = WindowCoordinator(model: model)
        let recipient = model.state.agents[0]
        WebProvider.optionalProviders.forEach { model.webAgents.setEnabled(true, for: $0) }
        let first = await model.prepareWebComparison("First comparison", recipientIDs: [recipient.id], providers: WebProvider.webDefaults + WebProvider.optionalProviders)!
        let muse = model.webAgents.sessions.first { $0.provider == .muse }!
        precondition(muse.fixture)
        model.webAgents.availableSessions.forEach { $0.connect() }
        try await waitUntil { model.webAgents.availableSessions.allSatisfy { $0.snapshot.ready } }
        let firstResults = await WebAgents.send("First comparison", to: model.webAgents.availableSessions, comparisonID: first)
        precondition(firstResults.values.allSatisfy { $0.status == .observed })
        let firstNativeSessions = Dictionary(uniqueKeysWithValues: model.webAgents.sessions.compactMap { session in session.state.localSessionIDs[first.uuidString].map { (session.provider, $0) } })
        await model.submit(first, retry: false)
        let second = await model.prepareWebComparison("Second comparison", recipientIDs: [], providers: WebProvider.webDefaults + WebProvider.optionalProviders)!
        let secondResults = await WebAgents.send("Second comparison", to: model.webAgents.availableSessions, comparisonID: second)
        precondition(secondResults.values.allSatisfy { $0.status == .observed })
        for session in model.webAgents.availableSessions {
            if session.provider.personalAgentProvider != nil {
                precondition(firstNativeSessions[session.provider] != session.state.localSessionIDs[second.uuidString])
            } else if session.provider == .dots {
                precondition(firstResults[session.provider]?.conversationURL == secondResults[session.provider]?.conversationURL)
            } else { precondition(firstResults[session.provider]?.conversationURL != secondResults[session.provider]?.conversationURL) }
        }
        model.setSharedDraft("Shared draft for B")
        model.openWebComparison(first)
        model.setSharedDraft("Shared draft for A")
        model.openWebComparison(second)
        precondition(model.state.draft == "Shared draft for B")
        model.openWebComparison(first)
        precondition(model.state.draft == "Shared draft for A")
        let restoredDrafts = try model.local.load()
        precondition(restoredDrafts.workspaceDrafts?[first.uuidString] == "Shared draft for A")
        precondition(restoredDrafts.workspaceDrafts?[second.uuidString] == "Shared draft for B")
        model.setSharedDraft("")
        print("PASS: actual AppModel switches independent A/B shared drafts and persists both across LocalStore reload.")
        model.coordinator?.open(first)
        try await waitUntil { model.webAgents.availableSessions.allSatisfy { session in
            if session.provider.personalAgentProvider != nil {
                return session.state.comparisonID == first && session.snapshot.messages.first?.text == "First comparison" && session.state.localSessionIDs[first.uuidString] == firstNativeSessions[session.provider]
            }
            return session.webView.url == firstResults[session.provider]?.conversationURL
        } }
        precondition(model.state.selection == [recipient.id])
        precondition(model.webAgents.selected.map(\.provider) == WebProvider.webDefaults + WebProvider.optionalProviders)
        precondition(model.webAgents.comparisonID == first)
        precondition(model.comparison(first)?.members.first?.submission == .submitted)
        model.webAgents.setEnabled(false, for: .codexCLI)
        model.openWebComparison(first)
        precondition(!model.webAgents.selected.contains { $0.provider == .codexCLI })
        let archivedCodex = model.webAgents.displayed.first { $0.provider == .codexCLI }!
        precondition(!archivedCodex.snapshot.ready && archivedCodex.snapshot.messages.first?.text == "First comparison")
        let disabledAttempt = await archivedCodex.send("Disabled archive cannot send", comparisonID: first)
        precondition(disabledAttempt == nil)
        model.webAgents.setComparison(nil)
        precondition(!model.webAgents.displayed.contains { $0.provider == .codexCLI })
        model.openWebComparison(first)
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
        // Exercise the same private Messages call used by PR #27's pane composer.
        model.coordinator = nil
        model.state.selection = [recipient.id]
        model.state.draft = "Native privacy original"
        await model.start()
        let privacyID = model.state.comparisons[0].id
        let privacyIndex = model.index(privacyID)!
        model.state.comparisons[privacyIndex].privateDrafts[recipient.id.uuidString] = "Native private detail"
        await model.followUp(privacyID, only: recipient.id)
        model.state.comparisons[privacyIndex].allDraft = "Native shared follow-up"
        await model.followUp(privacyID)
        let newcomer = model.state.agents[1]
        await model.addAgent(newcomer, to: privacyID)
        let joined = model.comparison(privacyID)!
        let joinedMember = joined.members.first { $0.id == newcomer.id }!
        let outgoing = model.transcript(joined, member: joinedMember).filter(\.outgoing).map(\.text)
        precondition(outgoing == ["Native privacy original", "Native shared follow-up"])
        precondition(joined.followUps.first?.sharedWithAll == false)
        print("PASS: PR #27's private Messages pane entry point stays private with one original recipient; adding another agent sends only original + shared follow-up. Actual AppModel, isolated simulated Messages.")

        model.webBroadcastBusy = true
        model.state.comparisons[privacyIndex].privateDrafts[recipient.id.uuidString] = "Private draft during broadcast"
        let beforePrivate = model.comparison(privacyID)!.followUps.count
        await model.followUp(privacyID, only: recipient.id)
        precondition(model.comparison(privacyID)!.followUps.count == beforePrivate, "Private send must wait for the web broadcast to finish")
        precondition(model.comparison(privacyID)!.privateDrafts[recipient.id.uuidString] == "Private draft during broadcast")
        model.webBroadcastBusy = false
        model.state.selection = [recipient.id, newcomer.id]
        model.state.draft = "Chronology original"
        await model.start()
        let orderID = model.state.comparisons[0].id
        let orderIndex = model.index(orderID)!
        var earlier = FollowUp(text: "Shared A", memberIDs: [recipient.id, newcomer.id])
        earlier.sharedWithAll = true
        earlier.created = model.state.comparisons[orderIndex].created
        earlier.states = [recipient.id.uuidString: .submitted, newcomer.id.uuidString: .failed]
        // Controlled receipt fixture: A reached the first recipient and failed before sending to the second.
        model.appendDemo(earlier.text, chat: model.comparison(orderID)!.members.first { $0.id == recipient.id }!.chat, outgoing: true)
        model.state.comparisons[orderIndex].followUps.append(earlier)
        model.state.comparisons[orderIndex].allDraft = "Shared B"
        await model.followUp(orderID)
        precondition(model.comparison(orderID)!.joiningContext().map(\.text) == ["Chronology original", "Shared B"])
        await model.followUp(orderID, retry: earlier.id)
        await model.followUp(orderID, retry: earlier.id)
        let third = model.state.agents[2]
        await model.addAgent(third, to: orderID)
        let ordered = model.comparison(orderID)!
        let thirdMember = ordered.members.first { $0.id == third.id }!
        precondition(model.transcript(ordered, member: thirdMember).filter(\.outgoing).map(\.text) == ["Chronology original", "Shared A", "Shared B"])
        precondition(ordered.joiningContext().dropFirst().map(\.followUpID) == [earlier.id, ordered.followUps[1].id])
        let webJoin = WebAgentSession(provider: .grok, storageURL: migrationDirectory.appendingPathComponent("plain-join.json"), fixture: true)
        webJoin.connect()
        try await waitUntil { webJoin.snapshot.ready }
        let joinedPrompt = ordered.joiningPrompt()
        precondition(joinedPrompt == "Chronology original\n\nShared A\n\nShared B")
        let joinedAttempt = await webJoin.send(joinedPrompt, comparisonID: orderID)
        precondition(joinedAttempt?.status == .observed)
        let renderedJoin = try await webJoin.webView.callAsyncJavaScript("return document.querySelector('#transcript article').textContent", arguments: [:], in: nil, contentWorld: .page) as? String
        precondition(renderedJoin == joinedPrompt)
        print("PASS: a new web agent receives only the original ask and shared follow-ups, in order, without generated instructions or labels. Local fixture; no real send.")
        print("PASS: partial-failure receipt fixture -> B sent through AppModel -> A retried through AppModel -> new agent receives Original,A,B once, in original order. No real sends.")
        model.state.selection = [recipient.id]
        model.state.draft = "Delayed broadcast original"
        await model.start()
        let raceID = model.state.comparisons[0].id
        let raceIndex = model.index(raceID)!
        model.state.comparisons[raceIndex].webProviders = [.muse]
        model.webBroadcastBusy = true
        let broadcastID = UUID()
        let gate = DelayedBroadcastGate()
        let delayed = await AgentBroadcast.send(draft: "Delayed shared ask", currentDraft: { "Delayed shared ask" }, clearDraft: {}, web: { text in
            while !gate.messagesFinished { try? await Task.sleep(for: .milliseconds(10)) }
            precondition(!model.busy && model.webBroadcastBusy)
            model.state.comparisons[raceIndex].privateDrafts[recipient.id.uuidString] = "Private reply while web is pending"
            let privateWindow = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 600, height: 650), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            privateWindow.title = "Delayed broadcast — isolated Messages fixture"
            privateWindow.contentView = NSHostingView(rootView: ConversationView(model: model, comparisonID: raceID, memberID: recipient.id))
            NSApplication.shared.setActivationPolicy(.regular)
            privateWindow.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate()
            defer { privateWindow.orderOut(nil); privateWindow.contentView = nil }
            privateWindow.contentView?.layoutSubtreeIfNeeded()
            try! await waitUntil { privateWindow.contentView.flatMap { privateEditor(in: $0) } != nil }
            let paneEditor = privateEditor(in: privateWindow.contentView!)!
            precondition(paneEditor.accessibilityLabel() == "Private reply to \(recipient.name)")
            let paneCount = model.comparison(raceID)!.followUps.count
            paneEditor.sendMessage?()
            try? await Task.sleep(for: .milliseconds(50))
            precondition(model.comparison(raceID)!.followUps.count == paneCount)
            precondition(model.comparison(raceID)!.privateDrafts[recipient.id.uuidString] == "Private reply while web is pending")
            privateWindow.contentView?.layoutSubtreeIfNeeded()
            privateWindow.contentView?.displayIfNeeded()
            if let path = ProcessInfo.processInfo.environment["MSGBLAST_RACE_CAPTURE"], let view = privateWindow.contentView?.superview,
               let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
            }
            let before = model.comparison(raceID)!.followUps.count
            await model.followUp(raceID, only: recipient.id)
            precondition(model.comparison(raceID)!.followUps.count == before)
            precondition(model.comparison(raceID)!.privateDrafts[recipient.id.uuidString] == "Private reply while web is pending")
            // Controlled ledger insertion stresses identity independently of the new private-send guard.
            var injected = FollowUp(text: "Injected private ledger reply", memberIDs: [recipient.id])
            injected.sharedWithAll = false; injected.states[recipient.id.uuidString] = .submitted
            model.state.comparisons[raceIndex].followUps.append(injected)
            var receipt = WebSendAttempt(text: text, status: .observed)
            receipt.comparisonID = raceID
            return [.muse: receipt]
        }, messages: { text in
            model.state.comparisons[raceIndex].allDraft = text
            await model.followUp(raceID, recipients: [recipient.id], newAttemptID: broadcastID)
            gate.messagesFinished = true
            return raceID
        })
        precondition(delayed.web[.muse]?.status == .observed)
        model.state.comparisons[raceIndex].completeSharedBroadcast(followUpID: broadcastID, recipients: [recipient.id])
        precondition(model.comparison(raceID)!.followUps.last!.sharedWithAll == false)
        model.webBroadcastBusy = false
        await model.followUp(raceID, only: recipient.id)
        await model.addAgent(third, to: raceID)
        let safe = model.comparison(raceID)!
        let safeMember = safe.members.first { $0.id == third.id }!
        precondition(model.transcript(safe, member: safeMember).filter(\.outgoing).map(\.text) == ["Delayed broadcast original", "Delayed shared ask"])
        print("PASS: deterministic delayed web completion preserves the exact broadcast UUID; private send is blocked with draft retained, injected later private ledger remains unmarked, and a new agent receives only Original + Shared. Actual AgentBroadcast + AppModel with simulated transport.")
        print("PASS: actual AppModel + WindowCoordinator restore comparison ID, native recipient, provider selection, saved website URLs including the ongoing Dots thread and separate Codex CLI/Claude Code sessions; disabled archived CLI remains readable without sending. All sends use local fixtures.")
    }
}
