import AppKit
import SwiftUI
import msgblastCore

@MainActor private final class DelayedBroadcastGate {
    var messagesFinished = false
}

@main struct SideChatModelCheck {
    @MainActor static func waitUntil(file: StaticString = #fileID, line: UInt = #line, _ check: () -> Bool) async throws {
        for _ in 0..<100 { if check() { return }; try await Task.sleep(for: .milliseconds(100)) }
        preconditionFailure("Model fixture did not reach expected state", file: file, line: line)
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
            do {
                if ProcessInfo.processInfo.arguments.contains("--permission-review-relaunch-fixture") { try runPermissionReviewRelaunchChecks() }
                else { try await runChecks() }
            }
            catch { fatalError("Isolated model fixture failed: \(error)") }
            application.stop(nil)
            let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)!
            application.postEvent(wake, atStart: true)
        }
        application.run()
    }
    @MainActor static func runPermissionReviewRelaunchChecks() throws {
        let model = AppModel()
        let root = model.local.url.deletingLastPathComponent()
        precondition(root.lastPathComponent.hasPrefix("msgblast-PermissionReview-"))
        defer { try? FileManager.default.removeItem(at: root) }
        model.state.onboarding = nil
        model.state.agentGrid = nil
        model.state.draft = "Permission review restart keeps this draft"
        let agent = model.state.agents[0]
        model.state.selection = [agent.id]
        model.webAgents.session(for: .grok)!.updateState { $0.selected = true }
        let grid = model.agentGridLayout
        let counts = model.telemetryAgentCounts
        try model.save()
        model.onboarding.reviewMessagesAgents()
        let relaunched = AppModel()
        precondition(relaunched.state.selection == [agent.id])
        precondition(relaunched.webAgents.session(for: .grok)!.state.selected)
        precondition(relaunched.state.draft == "Permission review restart keeps this draft")
        precondition(relaunched.state.agentGrid == grid)
        precondition(relaunched.telemetryAgentCounts == counts)
        print("PASS: actual same-store AppModel relaunch preserves Messages and website recipients, draft, inferred grid, and adoption baseline during permission review.")
    }
    @MainActor static func runChecks() async throws {
        _ = NSApplication.shared
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
        let lifecycleModel = AppModel()
        lifecycleModel.timer?.invalidate()
        let lifecycleAgent = lifecycleModel.state.agents[0]
        lifecycleModel.state.selection = [lifecycleAgent.id]
        lifecycleModel.state.draft = "Conversation lifecycle fixture"
        lifecycleModel.coordinator = WindowCoordinator(model: lifecycleModel)
        await lifecycleModel.start(recipientIDs: [lifecycleAgent.id])
        let lifecycleID = lifecycleModel.state.comparisons[0].id
        let window = NSApp.windows.first { $0.identifier?.rawValue == lifecycleID.uuidString + ":connected" }!
        let originalFrame = window.frame
        let originalNumber = window.windowNumber
        lifecycleModel.state.comparisons[0].allDraft = "Retained shared draft"
        lifecycleModel.state.comparisons[0].privateDrafts[lifecycleAgent.id.uuidString] = "Retained private draft"
        await lifecycleModel.addAgent(lifecycleModel.state.agents[1], to: lifecycleID)
        lifecycleModel.coordinator?.open(lifecycleID)
        precondition(window.windowNumber == originalNumber && window.frame == originalFrame && window.isVisible)
        precondition(lifecycleModel.comparison(lifecycleID)!.members.count == 2)
        let lifecycleWeb = lifecycleModel.webAgents.session(for: .chatgpt)!
        lifecycleModel.coordinator?.prepareJoiningWebAgent(lifecycleID)
        lifecycleWeb.updateState { $0.selected = true }
        lifecycleWeb.connect()
        try await waitUntil { lifecycleWeb.snapshot.ready }
        let joinedLifecycleWeb = await lifecycleModel.joinWebAgent(lifecycleWeb, comparisonID: lifecycleID)
        precondition(joinedLifecycleWeb)
        lifecycleModel.coordinator?.open(lifecycleID)
        precondition(window.windowNumber == originalNumber && window.frame == originalFrame && window.isVisible)
        precondition(lifecycleModel.state.draft == "Retained shared draft")
        precondition(lifecycleModel.comparison(lifecycleID)!.privateDrafts[lifecycleAgent.id.uuidString] == "Retained private draft")
        let otherID = await lifecycleModel.prepareWebComparison("Different conversation", recipientIDs: [], agents: [lifecycleWeb.id])!
        lifecycleModel.openWebComparison(otherID)
        try await Task.sleep(for: .milliseconds(300))
        window.contentView?.layoutSubtreeIfNeeded()
        precondition(window.identifier?.rawValue == lifecycleID.uuidString + ":connected")
        precondition(window.contentView.flatMap { transcriptText("Conversation lifecycle fixture", in: $0) } != nil)
        lifecycleModel.coordinator?.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: window))
        precondition(lifecycleModel.webAgents.comparisonID == lifecycleID)
        precondition(lifecycleModel.state.draft == "Retained shared draft")
        let lifecycleMember = lifecycleModel.comparison(lifecycleID)!.members[0]
        lifecycleModel.appendDemo("Before ending", chat: lifecycleMember.chat, outgoing: false)
        precondition(lifecycleModel.endConversation(lifecycleID))
        let savedEnded = try lifecycleModel.local.load().comparisons.first { $0.id == lifecycleID }!
        precondition(savedEnded.endedAt != nil)
        let kept = lifecycleModel.transcript(savedEnded, member: lifecycleMember).map(\.text)
        lifecycleModel.appendDemo("Late response", chat: lifecycleMember.chat, outgoing: false)
        precondition(lifecycleModel.transcript(savedEnded, member: lifecycleMember).map(\.text) == kept)
        precondition(lifecycleModel.messages[lifecycleMember.chat.id]!.last!.text == "Late response")
        let webHistory = savedEnded.endedWebHistory![lifecycleWeb.id.id]!
        _ = await lifecycleWeb.send("Agent history continues", comparisonID: lifecycleID)
        precondition(lifecycleModel.comparison(lifecycleID)!.endedWebHistory![lifecycleWeb.id.id]! == webHistory)
        precondition(lifecycleWeb.snapshot.messages.contains { $0.text == "Agent history continues" })
        let beforeEndedSend = lifecycleModel.comparison(lifecycleID)!.followUps.count
        await lifecycleModel.followUp(lifecycleID)
        precondition(lifecycleModel.comparison(lifecycleID)!.followUps.count == beforeEndedSend)
        precondition(lifecycleModel.coordinator!.windowShouldClose(window))
        window.close()
        lifecycleModel.webAgents.beginShutdown()
        await lifecycleModel.webAgents.cancelAndWait()
        print("PASS: membership updates keep the exact NSWindow and frame, shared/private drafts and conversation ID; persisted ending keeps history and excludes late Messages/web replies without stopping agent history.")
        let reopenModel = AppModel()
        reopenModel.coordinator = WindowCoordinator(model: reopenModel)
        let reopenID = await reopenModel.prepareWebComparison("Reopened workspace fixture", recipientIDs: [], agents: [])!
        let mainWindow = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 650), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        mainWindow.contentView = NSHostingView(rootView: AgentsWorkspaceView(model: reopenModel, web: reopenModel.webAgents, showingComparison: .constant(true))
            .background(ConversationCloseBridge(model: reopenModel, comparisonID: reopenID)))
        mainWindow.orderBack(nil)
        try await waitUntil { reopenModel.coordinator?.workspaceWindow === mainWindow }
        precondition(reopenModel.endConversation(reopenID))
        let reopenCutoff = reopenModel.comparison(reopenID)!.endedAt
        mainWindow.performClose(nil)
        precondition(!mainWindow.isVisible)
        precondition(reopenModel.coordinator!.reopenWorkspace())
        precondition(mainWindow.isVisible)
        mainWindow.performClose(nil)
        reopenModel.coordinator?.open(reopenID)
        precondition(mainWindow.isVisible)
        precondition(reopenModel.comparison(reopenID)?.endedAt == reopenCutoff)
        mainWindow.orderOut(nil)
        reopenModel.webAgents.beginShutdown()
        await reopenModel.webAgents.cancelAndWait()
        print("PASS: closed main workspace reopens through both app reopen and comparison menu without changing its cutoff or replacing its NSWindow.")
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
        precondition(gridModel.agentGridLayout.visibleIDs == [.web(.claudeCode)] + savedAgentIDs)
        precondition(!gridModel.agentGridLayout.visibleIDs.contains(.web(.muse)))
        precondition(gridModel.telemetryAgentCounts["claudeCode"] == 1)
        precondition(gridModel.telemetryAgentCounts["muse"] == nil)
        let manuallyAdded = AgentGridLayout(visibleIDs: [.web(.chatgpt)])
        precondition(gridModel.setAgentGrid(manuallyAdded))
        precondition(gridModel.agentGridLayout.visibleIDs == [.web(.chatgpt)], "Explicit membership survives a signed-out website")
        print("PASS: first-use grid excludes catalog suggestions, preserves configured providers and saved Messages agents, and keeps explicitly added signed-out agents.")
        let catalogTelemetry = AppModel()
        var knownPoke = Agent(contactID: "catalog-poke-fixture", name: "Poke 🌴", handles: ["poke@example.com"])
        catalogTelemetry.state.agents.append(knownPoke)
        catalogTelemetry.state.agentGrid = AgentGridLayout(visibleIDs: [.messages(knownPoke.id)])
        precondition(catalogTelemetry.telemetryAgentCounts == ["poke": 1])
        knownPoke.name = "Private contact name"
        catalogTelemetry.state.agents[catalogTelemetry.state.agents.count - 1] = knownPoke
        precondition(catalogTelemetry.telemetryAgentCounts == ["otherMessages": 1])
        print("PASS: known Poke adoption remains catalogued for legacy profiles, while personal names collapse into otherMessages without leaving the native model.")
        let legacyPermissionReview = AppModel()
        legacyPermissionReview.webAgents.session(for: .grok)!.updateState { $0.selected = true }
        precondition(legacyPermissionReview.state.onboarding == nil && legacyPermissionReview.state.agentGrid == nil)
        let inferredGrid = legacyPermissionReview.agentGridLayout
        let inferredCounts = legacyPermissionReview.telemetryAgentCounts
        legacyPermissionReview.onboarding.reviewMessagesAgents()
        precondition(legacyPermissionReview.state.agentGrid == inferredGrid)
        precondition(legacyPermissionReview.telemetryAgentCounts == inferredCounts)
        let permissionReview = AppModel()
        permissionReview.state.agentGrid = AgentGridLayout(visibleIDs: [.web(.grok)])
        permissionReview.state.draft = "Retain the unsent draft while reviewing access"
        let reviewSelection = permissionReview.state.selection
        let reviewCounts = permissionReview.telemetryAgentCounts
        permissionReview.onboarding.reviewMessagesAgents()
        precondition(permissionReview.state.onboarding?.connector == .messages)
        precondition(permissionReview.state.onboarding?.prerequisitesCompleted == false)
        precondition(permissionReview.state.agentGrid?.visibleIDs == [.web(.grok)])
        precondition(permissionReview.state.draft == "Retain the unsent draft while reviewing access")
        precondition(permissionReview.state.selection == reviewSelection)
        precondition(permissionReview.telemetryAgentCounts == reviewCounts)
        permissionReview.databaseAvailable = false
        precondition(permissionReview.messageConnectionStatus(permissionReview.state.agents[0]) == "Connect Messages")
        print("PASS: legacy profiles can review Messages permissions without erasing the grid, draft, recipients or adoption baseline; unavailable history asks for access rather than claiming a broken conversation.")
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
        let nativeJoinModel = AppModel()
        nativeJoinModel.timer?.invalidate()
        var nativeJoinComparison = Comparison(prompt: "Native join original context", members: [])
        nativeJoinComparison.sharedContext = [.init(text: "Shared follow-up before native join")]
        nativeJoinModel.state.comparisons.insert(nativeJoinComparison, at: 0)
        let expectedNativeContext = "Native join original context\n\nShared follow-up before native join"
        for provider in [WebProvider.chatgptApp, .dotsApp, .claudeApp] {
            let native = nativeJoinModel.webAgents.session(for: WebAgentID(provider: provider))!
            native.setEnabled(true)
            await native.connectDesktopConversation()
            precondition(native.snapshot.ready, "The simulated native app connection must be ready before joining")
            precondition(!nativeJoinModel.comparison(nativeJoinComparison.id)!.resolvedWebAgentIDs.contains(native.id))
            let attemptsBeforeJoin = native.state.attempts.count
            let nativeJoined = await nativeJoinModel.joinWebAgent(native, comparisonID: nativeJoinComparison.id)
            precondition(nativeJoined, "A native app must join through the same recipient flow as a website")
            precondition(nativeJoinModel.webAgents.comparisonID == nativeJoinComparison.id, "Joining must prepare the whole comparison, including its workspace identity")
            precondition(native.state.comparisonID == nativeJoinComparison.id)
            let attempts = native.state.attempts.filter { $0.comparisonID == nativeJoinComparison.id }
            precondition(native.state.attempts.count == attemptsBeforeJoin + 1 && attempts.count == 1)
            precondition(attempts[0].status == .observed && attempts[0].text == expectedNativeContext)
            let outgoing = native.state.localConversations[nativeJoinComparison.id.uuidString]!.filter { $0.role == "user" }
            precondition(outgoing.count == 1 && outgoing[0].text == expectedNativeContext, "Joining submits the accumulated shared context exactly once")
            let savedNativeJoin = try nativeJoinModel.local.load().comparisons.first { $0.id == nativeJoinComparison.id }!
            precondition(savedNativeJoin.resolvedWebAgentIDs.contains(native.id), "Successful native membership must survive a store reload")
            let joinedAgain = await nativeJoinModel.joinWebAgent(native, comparisonID: nativeJoinComparison.id)
            precondition(joinedAgain && native.state.attempts.count == attemptsBeforeJoin + 1, "Reopening an existing native recipient must not send its joining context again")
        }
        precondition(Set(nativeJoinModel.comparison(nativeJoinComparison.id)!.resolvedWebAgentIDs) == Set([WebAgentID(provider: .chatgptApp), .init(provider: .dotsApp), .init(provider: .claudeApp)]))
        nativeJoinModel.webAgents.beginShutdown()
        await nativeJoinModel.webAgents.cancelAndWait()
        print("PASS: ChatGPT App, Dots App and Claude App join through actual AppModel preparation, preserve comparison membership on reload, and submit the full simulated shared context exactly once across repeated joins.")
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
        let quickModel = AppModel()
        let quickContact = quickModel.state.agents[0]
        let quickDraft = quickModel.state.draft
        var quickGrid = quickModel.agentGridLayout
        quickGrid.hide(.messages(quickContact.id))
        precondition(quickModel.setAgentGrid(quickGrid))
        precondition(!quickModel.quickChatAgents.contains { $0.id == .messages(quickContact.id) })
        precondition(!quickModel.requestNewBlast(agent: .messages(quickContact.id)))
        quickGrid.add(.messages(quickContact.id))
        precondition(quickModel.setAgentGrid(quickGrid))
        precondition(quickModel.requestNewBlast(agent: .messages(quickContact.id)))
        precondition(quickModel.state.selection == [quickContact.id])
        precondition(quickModel.webAgents.selected.isEmpty)
        precondition(quickModel.isVisibleInAgentGrid(.messages(quickContact.id)))
        let quickWeb = quickModel.webAgents.session(for: WebAgentID(provider: .chatgpt))!
        quickWeb.connect()
        try await waitUntil { quickWeb.isReadyForOnboarding }
        let quickCopy = try quickModel.webAgents.duplicate(quickWeb, name: "Quick chat copy")
        quickCopy.connect()
        try await waitUntil { quickCopy.isReadyForOnboarding }
        var copyGrid = quickModel.agentGridLayout
        copyGrid.add(quickCopy.id.gridID)
        precondition(quickModel.setAgentGrid(copyGrid))
        precondition(quickModel.requestNewBlast(agent: quickCopy.id.gridID))
        precondition(quickModel.state.selection.isEmpty)
        precondition(quickModel.webAgents.selected.map(\.id) == [quickCopy.id])
        precondition(quickModel.newBlastShowsChat)
        precondition(quickModel.requestNewBlast())
        precondition(!quickModel.newBlastShowsChat)
        precondition(quickModel.webAgents.selected.map(\.id) == [quickCopy.id])
        quickModel.webAgents.setEnabled(true, for: .codexCLI)
        let quickCLI = quickModel.webAgents.session(for: WebAgentID(provider: .codexCLI))!
        try await waitUntil { quickCLI.isReadyForOnboarding }
        var cliGrid = quickModel.agentGridLayout
        cliGrid.add(quickCLI.id.gridID)
        precondition(quickModel.setAgentGrid(cliGrid))
        precondition(quickModel.requestNewBlast(agent: quickCLI.id.gridID))
        precondition(quickModel.webAgents.selected.map(\.id) == [quickCLI.id])
        let request = quickModel.newBlastRequest
        quickModel.webBroadcastBusy = true
        precondition(!quickModel.requestNewBlast(agent: .messages(quickContact.id)))
        precondition(quickModel.newBlastRequest == request)
        quickModel.webBroadcastBusy = false
        precondition(quickModel.state.draft == quickDraft)
        precondition(quickModel.state.comparisons.isEmpty)
        precondition(quickModel.webAgents.sessions.allSatisfy { $0.state.attempts.isEmpty })
        quickModel.timer?.invalidate()
        await quickModel.webAgents.cancelAndWait()
        print("PASS: quick access excludes hidden agents and selects grid Messages, a named website copy, and CLI exclusively; preserves drafts/selections and blocks during sends without submitting.")
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
        let nativeModel = AppModel()
        let nativeProviders: [WebProvider] = [.chatgptApp, .dotsApp, .claudeApp]
        let nativeSessions = nativeProviders.map { nativeModel.webAgents.session(for: WebAgentID(provider: $0))! }
        for session in nativeSessions {
            session.setEnabled(true)
            await session.connectDesktopConversation()
        }
        let nativeID = await nativeModel.prepareWebComparison("Native comparison fixture", recipientIDs: [], agents: nativeSessions.map(\.id))!
        let nativeReplies = await WebAgents.send("Native comparison fixture", to: nativeSessions, comparisonID: nativeID)
        precondition(nativeReplies.count == 3 && nativeReplies.values.allSatisfy { $0.status == .observed })
        let savedBindings = nativeSessions.map { $0.state.chatgptConversations[nativeID.uuidString] }
        let savedClaude = nativeSessions[2].state.claudeConversations[nativeID.uuidString]
        nativeModel.webAgents.setComparison(nil)
        nativeModel.openWebComparison(nativeID)
        for _ in 0..<100 where !nativeSessions.allSatisfy({ $0.snapshot.ready && $0.state.comparisonID == nativeID }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(nativeSessions.allSatisfy { $0.snapshot.ready && $0.state.comparisonID == nativeID })
        precondition(nativeSessions.map { $0.state.chatgptConversations[nativeID.uuidString] } == savedBindings)
        precondition(nativeSessions[2].state.claudeConversations[nativeID.uuidString] == savedClaude)
        precondition(Set(nativeModel.webAgents.selected.map(\.id)) == Set(nativeSessions.map(\.id)))
        let savedNativeComparison = try nativeModel.local.load().comparisons.first { $0.id == nativeID }!
        precondition(savedNativeComparison.resolvedWebAgentIDs == nativeSessions.map(\.id))
        nativeModel.webAgents.beginShutdown()
        await nativeModel.webAgents.cancelAndWait()
        print("PASS: actual AppModel + LocalStore reopen the three native providers with the same owned bindings and exact membership. Demo simulation; no live apps or sends.")
        let choiceModel = AppModel()
        let businessAddress = "urn:biz:00000000-0000-0000-0000-000000000001"
        let businessChat = Chat(id: "iMessage;-;" + businessAddress, handle: businessAddress, lastActivity: 0, displayName: "Fixture Poke", businessConversation: true)
        choiceModel.chats = [businessChat]
        choiceModel.appendBusinessChoiceFixture(chat: businessChat)
        let sourceChoice = choiceModel.messages[businessChat.id]!.last!
        let choiceMember = Member(agentID: UUID(), name: "Fixture Poke", chat: businessChat)
        precondition(choiceModel.canChooseBusinessOption(sourceChoice, member: choiceMember, optionID: 0))
        await choiceModel.chooseBusinessOption(sourceChoice, member: choiceMember, optionID: 0)
        precondition(choiceModel.messages[businessChat.id]!.filter(\.outgoing).map(\.text) == ["Find Plumbers"])
        precondition(choiceModel.businessChoiceAttempt(sourceChoice)?.status == .submitted)
        let choiceState = try choiceModel.local.load()
        precondition(choiceState.businessChoiceAttempts?[sourceChoice.guid]?.status == .submitted)
        await choiceModel.chooseBusinessOption(sourceChoice, member: choiceMember, optionID: 1)
        precondition(choiceModel.messages[businessChat.id]!.filter(\.outgoing).count == 1)
        choiceModel.webAgents.beginShutdown()
        await choiceModel.webAgents.cancelAndWait()
        print("PASS: Business choice controller submits one simulated choice, durably records the attempt and blocks a repeated action. No native Messages button was pressed.")
        print("PASS: actual AppModel + WindowCoordinator restore comparison ID, native recipient, provider selection, saved website URLs including the ongoing Dots thread and separate Codex CLI/Claude Code sessions; disabled archived CLI remains readable without sending. All sends use local fixtures.")
    }

    private static func photoResource(_ name: String, in fixtureRoot: URL) throws -> Data {
        let root = fixtureRoot.deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: root.appendingPathComponent("msgblast/Resources/WebAgentIcons/\(name).jpg"))
    }
}
