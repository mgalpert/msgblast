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
    @MainActor static func transcriptText(_ text: String, in view: NSView) -> NSTextView? {
        if let value = view as? NSTextView, !(value is AttachmentTextView), value.string == text { return value }
        for child in view.subviews { if let value = transcriptText(text, in: child) { return value } }
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
        try await performanceChecks()
        let scrollModel = AppModel()
        let scrollAgent = scrollModel.state.agents[0]
        let scrollID = await scrollModel.prepareWebComparison("Scroll fixture original", recipientIDs: Set(scrollModel.state.agents.prefix(3).map(\.id)), agents: [])!
        await scrollModel.submit(scrollID, retry: false)
        let scrollMember = scrollModel.comparison(scrollID)!.members.first { $0.id == scrollAgent.id }!
        try await waitUntil { (scrollModel.messages[scrollMember.chat.id]?.count ?? 0) >= 2 }
        for index in 0..<25 {
            scrollModel.appendDemo("History \(index): " + String(repeating: "Earlier context fills the transcript. ", count: 8), chat: scrollMember.chat, outgoing: false)
        }
        let scrollWindow = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 960, height: 430), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        scrollWindow.title = "Private send scroll fixture"
        scrollWindow.contentView = NSHostingView(rootView: ComparisonWorkspace(model: scrollModel, comparisonID: scrollID))
        scrollWindow.orderBack(nil)
        defer { scrollWindow.orderOut(nil); scrollWindow.contentView = nil }
        try await waitUntil { scrollWindow.contentView.flatMap { privateEditor(in: $0) } != nil }
        scrollWindow.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        let sentText = (1...40).map { "Private reply line \($0): sample wrapped content." }.joined(separator: "\n") + "\nEND OF PRIVATE MESSAGE"
        scrollModel.state.comparisons[scrollModel.index(scrollID)!].privateDrafts[scrollAgent.id.uuidString] = sentText
        try await Task.sleep(for: .milliseconds(300))
        let scrollEditor = privateEditor(in: scrollWindow.contentView!)!
        scrollWindow.makeFirstResponder(scrollEditor)
        let previousFollowUps = scrollModel.comparison(scrollID)!.followUps.count
        scrollEditor.sendMessage?()
        try await waitUntil { scrollModel.comparison(scrollID)!.followUps.count > previousFollowUps }
        try await Task.sleep(for: .milliseconds(500))
        scrollWindow.contentView?.layoutSubtreeIfNeeded()
        let sentIndex = scrollModel.messages[scrollMember.chat.id]!.firstIndex(where: { $0.outgoing && $0.text == sentText })!
        scrollModel.messages[scrollMember.chat.id]![sentIndex].reactions = [.init(id: "late-fixture-tapback", emoji: "✅", outgoing: false)]
        try await Task.sleep(for: .milliseconds(300))
        scrollWindow.contentView?.layoutSubtreeIfNeeded()
        let sentView = scrollWindow.contentView.flatMap { transcriptText(sentText, in: $0) }
        precondition(sentView != nil && sentView!.visibleRect.height >= min(17, sentView!.bounds.height) && sentView!.visibleRect.maxY >= sentView!.bounds.maxY - 1, "Private send is offscreen after submission; the user must not have to scroll")
        print("PASS: actual joined ComparisonWorkspace displays the bottom of a private send after a late tapback changes its height, without manual scrolling or waiting for a reply.")
        scrollModel.webAgents.beginShutdown()
        await scrollModel.webAgents.cancelAndWait()
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
        let gridModel = AppModel()
        gridModel.webAgents.setEnabled(true, for: .claudeCode)
        let savedAgentIDs = gridModel.state.agents.map { AgentGridID.messages($0.id) }
        precondition(gridModel.state.agentGrid == nil)
        precondition(gridModel.agentGridLayout.visibleIDs == AgentGridLayout.featured + [.web(.claudeCode), .web(.hark)] + savedAgentIDs)
        print("PASS: first-use grid preserves featured order, enabled optional providers, and every saved Messages agent.")
        let showcase = AppModel()
        let shown = showcase.state.agents[0]
        let hidden = showcase.state.agents[1]
        let original = showcase.webAgents.session(for: WebAgentID.chatgpt)!
        let copy = try showcase.webAgents.duplicate(original, name: "Hidden website copy")
        showcase.state.agentGrid = AgentGridLayout(visibleIDs: [.web(.muse), showcase.gridID(for: shown)])
        var showcaseComparison = Comparison(prompt: "Showcase recipients", members: [Member(agentID: shown.id, name: shown.name, chat: showcase.chats[0])])
        precondition(showcase.recipientMessageAgents(for: showcaseComparison).map(\.id) == [shown.id], "Connected hidden Messages agents must not appear in Send to")
        precondition(showcase.recipientWebSessions(for: showcaseComparison).map(\.id) == [.muse], "Unselected visible Muse must appear; connected hidden websites and copies must not")
        showcaseComparison.members.append(Member(agentID: hidden.id, name: hidden.name, chat: showcase.chats[1]))
        showcaseComparison.setWebAgents([copy.id])
        precondition(Set(showcase.recipientMessageAgents(for: showcaseComparison).map(\.id)) == Set([shown.id, hidden.id]), "Existing hidden members remain available")
        precondition(Set(showcase.recipientWebSessions(for: showcaseComparison).map(\.id)) == Set([.muse, copy.id]))
        showcase.state.comparisons.insert(showcaseComparison, at: 0)
        let showcaseMuse = showcase.webAgents.session(for: WebAgentID.muse)!
        showcaseMuse.updateState { $0.selected = true }; showcaseMuse.connect()
        try await waitUntil { showcaseMuse.snapshot.ready }
        let museJoined = await showcase.joinWebAgent(showcaseMuse, comparisonID: showcaseComparison.id)
        precondition(museJoined)
        let joinedAttemptCount = showcaseMuse.state.attempts.count
        let alreadyJoined = await showcase.joinWebAgent(showcaseMuse, comparisonID: showcaseComparison.id)
        precondition(alreadyJoined && showcaseMuse.state.attempts.count == joinedAttemptCount, "Opening an existing website member must not resend shared context")
        precondition(showcase.comparison(showcaseComparison.id)!.resolvedWebAgentIDs.contains(.muse))
        precondition(!showcase.comparison(showcaseComparison.id)!.members.contains { $0.id == showcase.state.agents[2].id })
        print("PASS: Send to offers only showcase agents plus saved members; unselected Muse can join a Messages comparison with simulated shared context, without adding hidden contacts.")
        showcase.webAgents.beginShutdown()
        await showcase.webAgents.cancelAndWait()
        let onboardingModel = AppModel()
        let connectedContact = Agent(contactID: "fixture-connected-fo", name: "Fo", handles: ["fo@example.com"])
        onboardingModel.state.selection = []
        onboardingModel.chats.append(Chat(id: "fixture-connected-fo", handle: "fo@example.com", lastActivity: 1))
        await onboardingModel.addAgent(connectedContact)
        precondition(onboardingModel.state.selection.isEmpty, "Adding a contact must not select a send recipient")
        var setup = OnboardingState()
        setup.selected = [.chatgpt, .fo, .claude]
        setup.completed = [.chatgpt, .fo]
        setup.skipped = [.claude]
        setup.messageAgentIDs["fo"] = connectedContact.id
        setup.stage = .feedback
        onboardingModel.state.onboarding = setup
        onboardingModel.onboarding.edit { $0.finish() }
        let setupIDs: [AgentGridID] = [.web(.chatgpt), .web(.claude), .featuredMessages(.fo)]
        precondition(onboardingModel.state.onboarding?.isFinished == true)
        precondition(onboardingModel.state.agentGrid?.visibleIDs == setupIDs)
        precondition(onboardingModel.state.selection.isEmpty, "Setup choices control grid membership, not recipient selection")
        precondition(onboardingModel.webAgents.selected.isEmpty, "Connected apps stay unchecked until the user selects them")
        let savedConnectedSetup = try onboardingModel.local.load()
        precondition(savedConnectedSetup.selection.isEmpty)
        precondition(savedConnectedSetup.agentGrid?.visibleIDs == setupIDs)
        onboardingModel.state.agentGrid = nil
        precondition(onboardingModel.agentGridLayout.visibleIDs == setupIDs)
        let customGrid = AgentGridLayout(visibleIDs: [.web(.claude), .web(.chatgpt)])
        onboardingModel.state.agentGrid = customGrid
        precondition(onboardingModel.agentGridLayout == customGrid)
        onboardingModel.state.onboarding = setup
        onboardingModel.onboarding.edit { $0.finish() }
        precondition(onboardingModel.state.agentGrid?.visibleIDs == [.featuredMessages(.fo), .web(.claude), .web(.chatgpt)])
        onboardingModel.state.selection = [connectedContact.id]
        let optedIn = onboardingModel.webAgents.session(for: .chatgpt)!
        optedIn.updateState { $0.selected = true }
        onboardingModel.onboarding.edit { _ in }
        precondition(onboardingModel.state.selection == [connectedContact.id], "Later edits must retain explicit recipient choices")
        precondition(onboardingModel.webAgents.selected.map(\.id) == [.chatgpt])
        let savedOptIn = try onboardingModel.local.load()
        precondition(savedOptIn.selection == [connectedContact.id])
        print("PASS: chosen setup agents stay visible but unchecked; added contacts are not recipients; saved explicit selections and custom grid order are preserved.")
        let photoModel = AppModel()
        let fixtureRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let oldPhoto = try Data(contentsOf: fixtureRoot.appendingPathComponent("instinct-legacy-placeholder.jpg"))
        let currentPhoto = try photoResource("instinct", in: fixtureRoot)
        let customPhoto = try photoResource("fo", in: fixtureRoot)
        var instinct = Agent(contactID: "fixture-photo-instinct", name: "Instinct", handles: ["instinct@example.com"], avatar: oldPhoto)
        photoModel.state.agents.append(instinct)
        func displayedInstinctPhoto() -> Data? {
            let entry = photoModel.agentGridCatalog.first { $0.id == .featuredMessages(.instinct) }!
            return AgentArtwork.avatar(for: entry.agent, name: entry.name)
        }
        precondition(displayedInstinctPhoto() == currentPhoto, "The saved legacy Instinct placeholder must not shadow the updated bundled photo")
        instinct.avatar = customPhoto
        photoModel.state.agents[photoModel.state.agents.count - 1] = instinct
        precondition(displayedInstinctPhoto() == customPhoto, "A genuine contact photo must retain priority")
        instinct.avatar = nil
        photoModel.state.agents[photoModel.state.agents.count - 1] = instinct
        precondition(displayedInstinctPhoto() == currentPhoto, "A saved contact without a photo must use featured artwork")
        print("PASS: Instinct's legacy cached placeholder upgrades to current artwork; custom contact photos retain priority and absent photos fall back.")
        let hiddenContact = gridModel.state.agents[0]
        let draftBeforeGrid = gridModel.state.draft
        var grid = gridModel.agentGridLayout
        grid.hide(.web(.muse)); grid.hide(.messages(hiddenContact.id))
        precondition(gridModel.setAgentGrid(grid))
        precondition(!gridModel.state.selection.contains(hiddenContact.id))
        gridModel.state.selection.insert(hiddenContact.id)
        gridModel.webAgents.restoreSelection(for: [.muse, .chatgpt])
        gridModel.selectWorkspace(nil)
        precondition(!gridModel.state.selection.contains(hiddenContact.id))
        precondition(!gridModel.webAgents.selected.contains { $0.provider == .muse })
        precondition(gridModel.webAgents.selected.contains { $0.provider == .chatgpt })
        gridModel.state.selection.insert(hiddenContact.id)
        gridModel.webAgents.restoreSelection(for: [.muse, .chatgpt])
        grid.add(.web(.muse)); grid.add(.messages(hiddenContact.id))
        precondition(gridModel.setAgentGrid(grid))
        precondition(!gridModel.state.selection.contains(hiddenContact.id))
        precondition(!gridModel.webAgents.selected.contains { $0.provider == .muse })
        precondition(gridModel.agentGridLayout.visibleIDs.first == .messages(hiddenContact.id))
        precondition(gridModel.state.agents.contains { $0.id == hiddenContact.id })
        precondition(gridModel.state.draft == draftBeforeGrid)
        print("PASS: actual AppModel hides and restores tiles without deleting contacts/drafts or inheriting archived recipient selections; new tiles take first position.")
        let model = AppModel()
        precondition(model.demo && model.local.url.path.contains("UIFixture"))
        model.coordinator = WindowCoordinator(model: model)
        let recipient = model.state.agents[0]
        var comparisonSessions: [WebAgentSession] {
            model.webAgents.availableSessions.filter { $0.provider.supportsSharedSubmissions }
        }
        WebProvider.optionalProviders.forEach { model.webAgents.setEnabled(true, for: $0) }
        let first = await model.prepareWebComparison("First comparison", recipientIDs: [recipient.id], agents: (WebProvider.webDefaults + WebProvider.optionalProviders).map { WebAgentID(provider: $0) })!
        let muse = model.webAgents.sessions.first { $0.provider == .muse }!
        precondition(muse.fixture)
        comparisonSessions.forEach { $0.connect() }
        try await waitUntil { comparisonSessions.allSatisfy { $0.snapshot.ready } }
        let firstResults = await WebAgents.send("First comparison", to: comparisonSessions, comparisonID: first)
        for (provider, result) in firstResults {
            precondition(result.status == .observed, "\(provider.provider.name) first send: \(result.status) · \(result.detail ?? "No detail")")
        }
        let firstNativeSessions = Dictionary(uniqueKeysWithValues: model.webAgents.sessions.compactMap { session in session.state.localSessionIDs[first.uuidString].map { (session.provider, $0) } })
        await model.submit(first, retry: false)
        let second = await model.prepareWebComparison("Second comparison", recipientIDs: [], agents: (WebProvider.webDefaults + WebProvider.optionalProviders).map { WebAgentID(provider: $0) })!
        let secondResults = await WebAgents.send("Second comparison", to: comparisonSessions, comparisonID: second)
        for (provider, result) in secondResults {
            precondition(result.status == .observed, "\(provider.provider.name) second send: \(result.status) · \(result.detail ?? "No detail")")
        }
        for session in comparisonSessions {
            if session.provider.personalAgentProvider != nil {
                precondition(firstNativeSessions[session.provider] != session.state.localSessionIDs[second.uuidString])
            } else if session.provider == .dots || session.provider.sharesOneConversation {
                precondition(firstResults[session.id]?.conversationURL == secondResults[session.id]?.conversationURL)
            } else { precondition(firstResults[session.id]?.conversationURL != secondResults[session.id]?.conversationURL) }
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
        try await waitUntil { comparisonSessions.allSatisfy { session in
            if session.provider.personalAgentProvider != nil {
                return session.state.comparisonID == first && session.snapshot.messages.first?.text == "First comparison" && session.state.localSessionIDs[first.uuidString] == firstNativeSessions[session.provider]
            }
            return session.webView.url == firstResults[session.id]?.conversationURL
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
        await model.start(recipientIDs: model.state.selection)
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
        await model.start(recipientIDs: model.state.selection)
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
        await model.start(recipientIDs: model.state.selection)
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
        let instanceModel = AppModel()
        let originalWeb = instanceModel.webAgents.session(for: WebAgentID.chatgpt)!
        let copiedWeb = try instanceModel.webAgents.duplicate(originalWeb, name: "ChatGPT fixture copy")
        let unusedWeb = try instanceModel.webAgents.duplicate(originalWeb, name: "Unselected fixture copy")
        var instanceGrid = instanceModel.agentGridLayout
        instanceGrid.add(copiedWeb.id.gridID); instanceGrid.add(unusedWeb.id.gridID)
        precondition(instanceModel.setAgentGrid(instanceGrid))
        let instanceComparison = await instanceModel.prepareWebComparison("Same provider twice", recipientIDs: [], agents: [originalWeb.id, copiedWeb.id])!
        instanceModel.openWebComparison(instanceComparison)
        precondition(Set(instanceModel.webAgents.selected.map(\.id)) == Set([originalWeb.id, copiedWeb.id]))
        let instanceResults = await WebAgents.send("Same provider twice", to: instanceModel.webAgents.selected, comparisonID: instanceComparison)
        precondition(instanceResults.count == 2 && instanceResults.values.allSatisfy { $0.status == .observed })
        precondition(instanceResults[originalWeb.id]!.conversationURL != instanceResults[copiedWeb.id]!.conversationURL)
        _ = await copiedWeb.send("Private copy follow-up", comparisonID: instanceComparison)
        precondition(!originalWeb.snapshot.messages.contains { $0.text == "Private copy follow-up" })
        let storedInstanceComparison = try instanceModel.local.load().comparisons.first { $0.id == instanceComparison }!
        precondition(storedInstanceComparison.resolvedWebAgentIDs == [originalWeb.id, copiedWeb.id])
        instanceModel.webAgents.restoreSelection(forAgentIDs: [unusedWeb.id])
        instanceModel.openWebComparison(instanceComparison)
        precondition(Set(instanceModel.webAgents.selected.map(\.id)) == Set([originalWeb.id, copiedWeb.id]))
        precondition(!unusedWeb.state.selected)
        instanceModel.webAgents.beginShutdown()
        await instanceModel.webAgents.cancelAndWait()
        print("PASS: actual AppModel + LocalStore + WebAgents preserve two ChatGPT identities in one comparison, separate chat URLs/private follow-ups, and exact restored membership. Local website fixtures only.")
        let choiceModel = AppModel()
        let businessAddress = "urn:biz:00000000-0000-0000-0000-000000000001"
        let businessChat = Chat(id: "iMessage;-;" + businessAddress, handle: businessAddress, lastActivity: 0, displayName: "Fixture Poke", businessConversation: true)
        choiceModel.chats = [businessChat]
        choiceModel.appendBusinessChoiceFixture(chat: businessChat)
        let sourceChoice = choiceModel.messages[businessChat.id]!.last!
        var choiceMember = Member(agentID: UUID(), name: "Fixture Poke", chat: businessChat)
        choiceMember.anchor = Anchor(rowID: 100, guid: "owned-business-prompt")
        let choiceComparison = Comparison(prompt: "Find repair options", members: [choiceMember])
        choiceModel.setPerformanceTracking(true)
        choiceModel.state.comparisons = [choiceComparison]
        choiceModel.messages[businessChat.id]!.insert(Message(id: 100, guid: "owned-business-prompt", chatID: businessChat.id, text: choiceComparison.prompt, outgoing: true), at: 0)
        choiceModel.performance.seedMessages(comparison: choiceComparison, member: choiceMember, transcript: [])
        choiceModel.performance.beginMessages(comparisonID: choiceComparison.id, member: choiceMember, text: choiceComparison.prompt, scope: .shared, requestID: UUID())
        choiceModel.captureMessages()
        precondition(choiceModel.canChooseBusinessOption(sourceChoice, member: choiceMember, optionID: 0))
        await choiceModel.chooseBusinessOption(sourceChoice, member: choiceMember, optionID: 0)
        precondition(choiceModel.messages[businessChat.id]!.filter { $0.outgoing && $0.guid != "owned-business-prompt" }.map(\.text) == ["Find Plumbers"])
        precondition(choiceModel.businessChoiceAttempt(sourceChoice)?.status == .submitted)
        let choicePublication = try ComparisonPublicationBuilder.build(events: choiceModel.performance.events, comparisonID: choiceComparison.id.uuidString)
        precondition(choicePublication.turns[0].replies[0].messages.first { $0.businessChoices != nil }?.businessChoices?.options.map(\.selected) == [true, false], "Choosing through the real app model must update share selection without a manual capture call")
        let choiceState = try choiceModel.local.load()
        precondition(choiceState.businessChoiceAttempts?[sourceChoice.guid]?.status == .submitted)
        await choiceModel.chooseBusinessOption(sourceChoice, member: choiceMember, optionID: 1)
        precondition(choiceModel.messages[businessChat.id]!.filter { $0.outgoing && $0.guid != "owned-business-prompt" }.count == 1)
        choiceModel.webAgents.beginShutdown()
        await choiceModel.webAgents.cancelAndWait()
        print("PASS: Business choice controller submits one simulated choice, durably records the attempt and blocks a repeated action. No native Messages button was pressed.")
        print("PASS: actual AppModel + WindowCoordinator restore comparison ID, native recipient, provider selection, saved website URLs including the ongoing Dots thread and separate Codex CLI/Claude Code sessions; disabled archived CLI remains readable without sending. All sends use local fixtures.")
    }

    @MainActor private static func performanceChecks() async throws {
        let model = AppModel()
        defer { model.webAgents.beginShutdown(); model.timer?.invalidate(); try? FileManager.default.removeItem(at: model.local.url.deletingLastPathComponent()) }
        precondition(!model.state.performanceTrackingEnabled && model.performance.events.isEmpty)
        model.webAgents.setEnabled(true, for: .codexCLI)
        model.webAgents.setEnabled(true, for: .grokbot)
        let native = model.webAgents.session(for: .codexCLI)!
        let web = model.webAgents.session(for: .chatgpt)!
        let bot = model.webAgents.session(for: .grokbot)!
        let recipient = model.state.agents[0]
        model.setPerformanceTracking(true)
        let id = await model.prepareWebComparison("Synthetic recording fixture", recipientIDs: [recipient.id], agents: [web.id, native.id, bot.id])!
        _ = await model.webAgents.prepareComparison(id, for: [web, native, bot])
        let initialGroup = PerformanceRequestGroup(id: id.uuidString, targetAgentIDs: [recipient.id.uuidString, web.id.id, native.id.id, bot.id.id])
        await model.submit(id, retry: false, recordingGroup: initialGroup)
        let results = await WebAgents.send("Synthetic recording fixture", to: [web, native, bot], comparisonID: id, scope: .shared, requestGroup: initialGroup)
        precondition(results.count == 3)
        await bot.refresh()
        for _ in 0..<30 {
            await web.refresh()
            if Set(model.performance.replies.map { $0.agent.connection }).count == 4 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let replies = model.performance.replies
        precondition(Set(replies.map { $0.agent.connection }) == Set([.website, .cli, .messages, .grokBot]), "Every actual fixture connector must record its replies")
        precondition(replies.allSatisfy { $0.scope == .shared }, "Original shared reply scope is preserved")
        let reply = replies.first { $0.agent.connection == .cli }!
        precondition(PerformanceMetrics.firstReplyMS(events: model.performance.events, turnID: reply.turnID) != nil)
        model.performance.feedback(reply, .favorite)
        precondition(model.performance.replies.first { $0.id == reply.id }?.feedback == .favorite)
        model.performance.feedback(model.performance.replies.first { $0.id == reply.id }!, .negative)
        precondition(model.performance.replies.first { $0.id == reply.id }?.feedback == .negative)
        _ = await native.send("Synthetic private follow-up", comparisonID: id, scope: .private)
        precondition(model.performance.replies.last { $0.agent.connection == .cli }?.scope == .private)
        let privateTurn = model.performance.events.last { $0.kind == .turnStarted && $0.agent?.connection == .cli }!
        precondition(privateTurn.turnPosition == 1)
        // A normal incoming Messages reply need not be threaded.
        if let index = model.messages[model.comparison(id)!.members[0].chat.id]?.lastIndex(where: { !$0.outgoing }) {
            let chat = model.comparison(id)!.members[0].chat.id
            let firstReply = model.messages[chat]![index]
            model.messages[chat]![index].replyTo = nil
            model.messages[chat]![index].text += " Edited visible reply."
            let captured = model.performance.replies.last { $0.messageID == firstReply.guid }!
            precondition(captured.turnID != nil, "Unambiguous ordinary incoming replies use the owned outgoing receipt")
        }
        let repeated = "Synthetic recording fixture"
        let sharedActionID = UUID()
        let sharedGroup = PerformanceRequestGroup(id: sharedActionID.uuidString, targetAgentIDs: initialGroup.targetAgentIDs)
        _ = await AgentBroadcast.send(draft: repeated, currentDraft: { repeated }, clearDraft: {}, web: { text in
            await WebAgents.send(text, to: [web, native, bot], comparisonID: id, scope: .shared, requestGroup: sharedGroup)
        }, messages: { text in
            model.state.comparisons[model.index(id)!].allDraft = text
            await model.followUp(id, recipients: [recipient.id], newAttemptID: sharedActionID, recordingScope: .shared, recordingGroup: sharedGroup)
            return id
        })
        await bot.refresh()
        let sharedTurns = model.performance.events.filter { $0.kind == .turnStarted && $0.requestGroupID == sharedGroup.id }
        precondition(sharedTurns.count == 4 && sharedTurns.allSatisfy { $0.targetAgentIDs == initialGroup.targetAgentIDs })
        precondition(Set(sharedTurns.compactMap(\.agent?.id)) == Set(initialGroup.targetAgentIDs))
        precondition(sharedGroup.id != initialGroup.id && sharedTurns.allSatisfy { $0.text == repeated })
        let positions = sharedTurns.compactMap { $0.turnPosition }
        precondition(Set(positions).count > 1, "Private turns must not be used to align shared follow-ups by per-agent position")
        let subsetActionID = UUID()
        let subsetGroup = PerformanceRequestGroup(id: subsetActionID.uuidString, targetAgentIDs: [recipient.id.uuidString, web.id.id, native.id.id])
        _ = await AgentBroadcast.send(draft: repeated, currentDraft: { repeated }, clearDraft: {}, web: { text in
            await WebAgents.send(text, to: [web, native], comparisonID: id, scope: .private, requestGroup: subsetGroup)
        }, messages: { text in
            model.state.comparisons[model.index(id)!].allDraft = text
            await model.followUp(id, recipients: [recipient.id], newAttemptID: subsetActionID, recordingScope: .private, recordingGroup: subsetGroup)
            return id
        })
        let subsetTurns = model.performance.events.filter { $0.kind == .turnStarted && $0.requestGroupID == subsetGroup.id }
        precondition(subsetTurns.count == 3 && subsetTurns.allSatisfy { $0.targetAgentIDs == subsetGroup.targetAgentIDs })
        precondition(!subsetTurns.contains { $0.agent?.id == bot.id.id } && !subsetGroup.targetAgentIDs.contains(bot.id.id))
        print("PASS: actual broadcast hooks preserve shared action identity after private turns and repeated text; target IDs exclude the Bot from a later subset action without guessing by text or position.")
        let comparisonIndex = model.index(id)!
        model.state.comparisons[comparisonIndex].allDraft = "Synthetic actual Messages follow-up"
        await model.followUp(id, recipients: [recipient.id], recordingScope: .private)
        try await waitUntil { model.performance.replies.contains { $0.agent.connection == .messages && $0.scope == .private } }
        let messageFollowUp = model.performance.replies.last { $0.agent.connection == .messages && $0.scope == .private }!
        precondition(PerformanceMetrics.firstReplyMS(events: model.performance.events, turnID: messageFollowUp.turnID) != nil)
        let other = model.webAgents.session(for: .claude)!
        let copy = try model.webAgents.duplicate(web, name: "Renamed helper")
        model.performance.attach(model.webAgents)
        _ = await model.webAgents.prepareComparison(id, for: [web, other, copy])
        _ = await WebAgents.send("Synthetic canonical provider check", to: [web, other, copy], comparisonID: id, scope: .shared)
        for _ in 0..<15 { await web.refresh(); await other.refresh(); await copy.refresh(); try await Task.sleep(for: .milliseconds(50)) }
        let identities = model.performance.events.filter { $0.kind == .turnStarted && $0.text == "Synthetic canonical provider check" }.compactMap(\.agent)
        precondition(Set(identities.compactMap(\.provider)) == Set(["chatgpt", "claude"]))
        precondition(Set(identities.map(\.id)).count == 3 && identities.allSatisfy { $0.model == nil })
        let beforeManual = model.performance.events.filter { $0.kind == .turnStarted && $0.agent?.id == web.id.id }.count
        _ = try await web.webView.callAsyncJavaScript("const input=document.querySelector('textarea');input.value='Synthetic manual follow-up';input.dispatchEvent(new Event('input',{bubbles:true}));document.querySelector('#fixture-send').click()", arguments: [:], in: nil, contentWorld: .page)
        try await Task.sleep(for: .milliseconds(500)); await web.refresh()
        let manual = model.performance.events.last { $0.kind == .turnStarted && $0.text == "Synthetic manual follow-up" }
        precondition(manual != nil && manual?.scope == .unknown)
        precondition(model.performance.events.filter { $0.kind == .turnStarted && $0.agent?.id == web.id.id }.count == beforeManual + 1)
        precondition(!model.performance.events.contains { $0.kind == .dispatched && $0.turnID == manual?.turnID })
        _ = try await web.webView.callAsyncJavaScript("const reply=[...document.querySelectorAll('[data-message-author-role=assistant]')].at(-1);const hidden=document.createElement('span');hidden.style.display='none';hidden.textContent='MSGBLAST_PRIVATE_DOM_PAYLOAD';reply.append(hidden);const script=document.createElement('script');script.textContent='/* MSGBLAST_PRIVATE_DOM_PAYLOAD */';reply.append(script);const top=reply.cloneNode(true);top.hidden=true;top.dataset.messageId='hidden-fixture-id';top.textContent='MSGBLAST_PRIVATE_DOM_PAYLOAD';reply.after(top)", arguments: [:], in: nil, contentWorld: .page)
        await web.refresh()
        _ = try await web.webView.callAsyncJavaScript("const formatted=document.createElement('article');formatted.dataset.messageAuthorRole='assistant';formatted.dataset.messageId='formatting-fixture';formatted.innerHTML=markup;document.getElementById('transcript').append(formatted)", arguments: ["markup": "<p>First paragraph.<br>Second line.</p><p>Another paragraph.</p><pre><code>def example():\n    value = 1\n    return value\n</code></pre><span style='display:none'>MSGBLAST_PRIVATE_DOM_PAYLOAD</span>"], in: nil, contentWorld: .page)
        await web.refresh()
        let formatted = model.performance.replies.last { $0.messageID.hasSuffix(":formatting-fixture") }!
        precondition(formatted.text.contains("First paragraph.\nSecond line.\n\nAnother paragraph."))
        precondition(formatted.text == "First paragraph.\nSecond line.\n\nAnother paragraph.\n\ndef example():\n    value = 1\n    return value\n")
        let diskProjection = try PerformanceRecorder(directory: model.local.url.deletingLastPathComponent(), fixture: true)
        precondition(diskProjection.replies.last { $0.messageID.hasSuffix(":formatting-fixture") }?.text == formatted.text)
        let journal = try String(contentsOf: model.local.url.deletingLastPathComponent().appendingPathComponent("Performance/events.jsonl"), encoding: .utf8)
        precondition(!journal.contains("MSGBLAST_PRIVATE_DOM_PAYLOAD") && !model.performance.replies.contains { $0.text.contains("MSGBLAST_PRIVATE_DOM_PAYLOAD") })
        print("PASS: actual WebKit capture preserves canonical providers/copy identity and manual follow-up membership; hidden DOM elements, descendants, and scripts never enter the journal.")
        model.setPerformanceTracking(false)
        let count = model.performance.events.count
        _ = await native.send("Synthetic disabled follow-up", comparisonID: id, scope: .private)
        precondition(model.performance.events.count == count && !web.performanceObservationEnabled)
        let restored = try PerformanceRecorder(directory: model.local.url.deletingLastPathComponent(), fixture: true)
        precondition(restored.events.count == count)
        model.setPerformanceTracking(true)
        let beforeSleep = model.performance.events.count
        model.performance.gapAll(reason: "synthetic-sleep")
        precondition(model.performance.events.count == beforeSleep, "Closed historical comparisons cannot be resurrected by sleep")
        try messagesReceiptChecks()
        try await captureFailureChecks()
        print("PASS: actual AppModel + WebKit website + Messages + CLI + Bot synthetic sends preserve scopes, local timing, feedback revisions, disk restoration, and default/off boundaries. No live requests.")
    }

    @MainActor private static func messagesReceiptChecks() throws {
        let model = AppModel(); model.setPerformanceTracking(true)
        defer { model.timer?.invalidate(); model.webAgents.beginShutdown(); try? FileManager.default.removeItem(at: model.local.url.deletingLastPathComponent()) }
        let agent = model.state.agents[0], chat = model.chats[0]
        var member = Member(agentID: agent.id, name: agent.name, chat: chat)
        member.anchor = Anchor(rowID: 1, guid: "owned-original")
        var comparison = Comparison(prompt: "Synthetic original", members: [member])
        model.performance.seedMessages(comparison: comparison, member: member, transcript: [])
        let originalRequest = UUID()
        model.performance.beginMessages(comparisonID: comparison.id, member: member, text: comparison.prompt, scope: .shared, requestID: originalRequest)
        model.performance.messagesStatus(comparisonID: comparison.id, member: member, requestID: originalRequest, kind: .dispatched)
        let original = Message(id: 1, guid: "owned-original", chatID: chat.id, text: comparison.prompt, outgoing: true)
        let reply = Message(id: 2, guid: "normal-reply", chatID: chat.id, text: "Ordinary reply without threading", outgoing: false)
        model.performance.observeMessages(comparison: comparison, member: member, transcript: [original, reply])
        precondition(model.performance.replies.last?.turnID != nil)
        precondition(PerformanceMetrics.firstReplyMS(events: model.performance.events, turnID: model.performance.replies.last?.turnID) != nil)
        let afterReply = model.performance.events.count
        model.performance.observeMessages(comparison: comparison, member: member, transcript: [original, reply])
        precondition(model.performance.events.count == afterReply, "Unchanged Messages refresh appends nothing")
        var follow = FollowUp(text: "Synthetic follow-up", memberIDs: [member.id]); follow.sharedWithAll = false
        var payload = OutgoingPayload(text: follow.text, attachments: [])
        payload.parts[0].anchor = Anchor(rowID: 3, guid: "owned-follow-up")
        follow.payloads = [member.id.uuidString: payload]; comparison.followUps = [follow]
        model.performance.beginMessages(comparisonID: comparison.id, member: member, text: follow.text, scope: .private, requestID: UUID(), followUpID: follow.id)
        let outgoing = Message(id: 3, guid: "owned-follow-up", chatID: chat.id, text: follow.text, outgoing: true)
        let following = Message(id: 4, guid: "normal-follow-up-reply", chatID: chat.id, text: "Ordinary follow-up answer", outgoing: false)
        model.performance.observeMessages(comparison: comparison, member: member, transcript: [original, reply, outgoing, following])
        precondition(model.performance.replies.last?.scope == .private && model.performance.replies.last?.turnID != nil)
        let manual = Message(id: 5, guid: "unowned-send", chatID: chat.id, text: "Manual outside msgblast", outgoing: true)
        let ambiguous = Message(id: 6, guid: "unassigned-reply", chatID: chat.id, text: "Cannot infer ownership", outgoing: false)
        model.performance.observeMessages(comparison: comparison, member: member, transcript: [original, reply, outgoing, following, manual, ambiguous])
        precondition(model.performance.replies.last?.turnID == nil)
        var plain = FollowUp(text: "Plain-text follow-up", memberIDs: [member.id]); plain.sharedWithAll = false; plain.states[member.id.uuidString] = .submitted
        comparison.followUps.append(plain)
        model.performance.beginMessages(comparisonID: comparison.id, member: member, text: plain.text, scope: .private, requestID: UUID(), followUpID: plain.id)
        let plainOutgoing = Message(id: 7, guid: "plain-owned-follow", chatID: chat.id, text: plain.text, outgoing: true)
        let plainReply = Message(id: 8, guid: "plain-follow-reply", chatID: chat.id, text: "Unambiguous plain follow-up answer", outgoing: false)
        model.performance.observeMessages(comparison: comparison, member: member, transcript: [original, reply, outgoing, following, manual, ambiguous, plainOutgoing, plainReply])
        precondition(model.performance.replies.last?.turnID != nil && model.performance.replies.last?.scope == .private)
        var pending = comparison; pending.id = UUID()
        model.performance.seedMessages(comparison: pending, member: member, transcript: [])
        model.performance.beginMessages(comparisonID: pending.id, member: member, text: "Pending", scope: .shared, requestID: UUID())
        model.performance.beginMessages(comparisonID: pending.id, member: member, text: "Overlapping", scope: .private, requestID: UUID(), followUpID: follow.id)
        model.performance.observeMessages(comparison: pending, member: member, transcript: [original, outgoing, following])
        precondition(model.performance.replies.last?.turnID == nil, "Overlapping pending turns remain unassigned without explicit source membership")
        precondition(!model.performance.events.contains { $0.agent?.connection == .messages && $0.kind == .completed })
        print("PASS: Messages controller uses owned original/follow-up payload anchors for nil-replyTo replies, retains unowned/overlap ambiguity, deduplicates refresh, and never infers completion.")
    }

    @MainActor private static func captureFailureChecks() async throws {
        let model = AppModel(); model.webAgents.setEnabled(true, for: .codexCLI); model.setPerformanceTracking(true)
        defer { model.timer?.invalidate(); model.webAgents.beginShutdown(); try? FileManager.default.removeItem(at: model.local.url.deletingLastPathComponent()) }
        let native = model.webAgents.session(for: .codexCLI)!, comparison = UUID()
        _ = await native.send("Synthetic healthy recording", comparisonID: comparison, scope: .shared)
        let journal = model.local.url.deletingLastPathComponent().appendingPathComponent("Performance/events.jsonl")
        var damaged = try Data(contentsOf: journal); damaged.append(Data("synthetic-torn-append".utf8)); try damaged.write(to: journal)
        let result = await native.send("Synthetic send while recorder fails", comparisonID: comparison, scope: .private)
        precondition(result?.status == .observed && model.performance.error != nil && !model.performance.enabled && !native.performanceObservationEnabled)
        precondition(native.state.attempts.filter { $0.text == "Synthetic send while recorder fails" }.count == 1)
        let preserved = try Data(contentsOf: journal)
        precondition(preserved == damaged)
        model.setPerformanceTracking(false); model.performance.deleteAll(); model.setPerformanceTracking(true)
        _ = await native.send("Synthetic after explicit recording recovery", comparisonID: comparison, scope: .private)
        precondition(model.performance.error == nil && model.performance.enabled && !model.performance.events.isEmpty)
        let canceled = Task { @MainActor in await native.send("Synthetic canceled reply", comparisonID: UUID(), scope: .private) }
        for _ in 0..<20 { if native.isSending { break }; try await Task.sleep(for: .milliseconds(10)) }
        native.cancelNativeRequest(); _ = await canceled.value
        precondition(model.performance.events.contains { $0.kind == .observationState && $0.reason == "cancellation-requested" })
        precondition(model.performance.events.contains { $0.kind == .outcome && $0.reason == "canceled" })
        print("PASS: actual native send completes exactly once while failed recording detaches observers and preserves damaged bytes; explicit local deletion recovers recording without resending.")
    }

    private static func photoResource(_ name: String, in fixtureRoot: URL) throws -> Data {
        let root = fixtureRoot.deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: root.appendingPathComponent("msgblast/Resources/WebAgentIcons/\(name).jpg"))
    }
}
