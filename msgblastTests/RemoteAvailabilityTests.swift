import XCTest
@testable import msgblastCore
import msgblastRemoteProtocol

@MainActor
final class RemoteAvailabilityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func signals(_ provider: WebProvider, _ edit: (inout AgentSessionSignals) -> Void = { _ in }) -> AgentSessionSignals {
        var s = AgentSessionSignals(agentID: provider.rawValue, gridID: .web(provider), provider: provider, name: provider.name, isEnabled: true, isStorageAvailable: true,
                                    selected: true, connected: true, isSending: false, loading: false, snapshotReady: true, snapshotReason: "ready", signedIn: true, signedOut: nil)
        if provider.desktopApp != nil { s.desktopInstalled = true; s.desktopRunning = true; s.desktopReady = true; s.hasDesktopBinding = true }
        if provider == .grokbot { s.grokBotConfigured = true }
        if provider.personalAgentProvider != nil { s.accountStatus = .subscription }
        edit(&s)
        return s
    }
    private func allowed() -> MacAvailabilityInputs {
        var m = MacAvailabilityInputs()
        m.accessibility = .allowed; m.screenRecording = .allowed; m.driverInstalled = true
        m.fullDiskAccess = .allowed; m.contacts = .allowed; m.automation = .allowed
        m.databaseAvailable = true; m.databaseStatus = "ok"; m.messagesSendsAllowed = true
        return m
    }
    private func evaluate(_ s: AgentSessionSignals, _ m: MacAvailabilityInputs? = nil, otherDesktopSending: Bool = false) -> AgentAvailability {
        AvailabilityCalculator.availability(s, inputs: m ?? allowed(), otherDesktopSending: otherDesktopSending, now: now)
    }
    private func codes(_ a: AgentAvailability) -> [AvailabilityReasonCode] { a.reasons.map(\.code) }

    func testEveryProviderMapsToAProductAndForm() {
        let forms = Dictionary(grouping: WebProvider.allCases, by: AvailabilityCalculator.form).mapValues { Set($0) }
        XCTAssertEqual(forms[.macApp], [.museApp, .grokBotApp, .wabi, .geminiApp, .chatgptApp, .dotsApp, .claudeApp])
        XCTAssertEqual(forms[.cli], [.codexCLI, .claudeCode])
        XCTAssertEqual(forms[.webhookBot], [.grokbot])
        XCTAssertEqual(forms[.website], [.muse, .chatgpt, .claude, .grok, .dots, .os3, .hark])
        XCTAssertEqual(Set([WebProvider.chatgpt, .chatgptApp, .codexCLI].map(AvailabilityCalculator.product)), [.chatgpt], "Forms of one product group together")
        XCTAssertEqual(evaluate(signals(.codexCLI)).formLabel, "Codex CLI")
        XCTAssertEqual(evaluate(signals(.chatgptApp)).formLabel, "ChatGPT · Mac app")
    }

    func testWebsiteStates() {
        XCTAssertEqual(evaluate(signals(.claude)).readiness, .ready)
        let unknown = evaluate(signals(.grok) { $0.signedIn = nil; $0.connected = false })
        XCTAssertEqual(unknown.readiness, .ready, "The send path checks sign-in; availability never loads the page")
        XCTAssertEqual(codes(unknown), [.signInUnknown]); XCTAssertEqual(unknown.source, .lastKnown)
        let signedOut = evaluate(signals(.chatgpt) { $0.signedIn = false })
        XCTAssertEqual(signedOut.readiness, .blocked); XCTAssertEqual(codes(signedOut), [.signedOut]); XCTAssertEqual(signedOut.reasons[0].fixOn, .mac)
        XCTAssertEqual(codes(evaluate(signals(.dots) { $0.signedIn = nil; $0.signedOut = true })), [.signedOut])
        if case .busy = evaluate(signals(.claude) { $0.isSending = true }).readiness {} else { XCTFail("Sending is busy") }
        let dialog = evaluate(signals(.claude) { $0.snapshotReady = false; $0.snapshotReason = "Finish the open dialog in Claude first." })
        XCTAssertEqual(dialog.readiness, .blocked); XCTAssertEqual(codes(dialog), [.dialogOpen])
        if case .busy = evaluate(signals(.grok) { $0.snapshotReady = false; $0.snapshotReason = "Wait for Grok to finish its current reply." }).readiness {} else { XCTFail("Generating is busy") }
        let hark = evaluate(signals(.hark))
        XCTAssertEqual(hark.readiness, .unavailable); XCTAssertEqual(codes(hark), [.noSharedSends]); XCTAssertFalse(hark.capabilities.sharedSend)
        XCTAssertEqual(codes(evaluate(signals(.muse) { $0.isEnabled = false })), [.disabled])
        XCTAssertEqual(codes(evaluate(signals(.muse) { $0.isStorageAvailable = false })), [.storageFailed])
        XCTAssertTrue(evaluate(signals(.chatgpt)).capabilities.namedCopies)
        XCTAssertTrue(evaluate(signals(.os3)).capabilities.sharesOneConversation)
    }

    func testMacAppStates() {
        XCTAssertEqual(evaluate(signals(.claudeApp)).readiness, .ready)
        XCTAssertEqual(evaluate(signals(.claudeApp)).source, .lastKnown, "Desktop readiness is only refreshed by explicit Mac paths")
        let closed = evaluate(signals(.chatgptApp) { $0.desktopRunning = false; $0.desktopReady = false })
        XCTAssertEqual(closed.readiness, .readyWillLaunch, "A send will open and activate the app; the phone must say so")
        XCTAssertEqual(codes(closed), [.appNotRunning])
        let missing = evaluate(signals(.wabi) { $0.desktopInstalled = false; $0.desktopRunning = false })
        XCTAssertEqual(missing.readiness, .unavailable); XCTAssertEqual(codes(missing), [.notInstalled])

        var denied = allowed(); denied.accessibility = .denied; denied.screenRecording = .denied; denied.driverInstalled = false
        let permissions = evaluate(signals(.museApp), denied)
        XCTAssertEqual(permissions.readiness, .blocked)
        XCTAssertEqual(codes(permissions), [.driverUnavailable, .permissionMissing, .permissionMissing])
        XCTAssertEqual(permissions.reasons.compactMap(\.permission), [.accessibility, .screenRecording])
        XCTAssertTrue(permissions.reasons.allSatisfy { $0.fixOn == .mac })

        let pending = evaluate(signals(.dotsApp) { $0.unresolvedAttemptIDs = ["A1"] })
        XCTAssertEqual(pending.readiness, .blocked); XCTAssertEqual(pending.reasons.first?.attemptID, "A1"); XCTAssertEqual(pending.reasons.first?.fixOn, .phone)
        if case .busy = evaluate(signals(.claudeApp) { $0.isSending = true }).readiness {} else { XCTFail("Sending is busy") }
        if case .busy = evaluate(signals(.claudeApp) { $0.loading = true }).readiness {} else { XCTFail("Connection checks are busy") }
        XCTAssertEqual(codes(evaluate(signals(.grokBotApp) { $0.hasDesktopBinding = false; $0.desktopReady = false })), [.notConnected])
        XCTAssertEqual(codes(evaluate(signals(.chatgptApp) { $0.desktopReady = false; $0.desktopError = "Keep one main window open and dismiss any dialogs." })), [.dialogOpen])
        XCTAssertEqual(codes(evaluate(signals(.chatgptApp) { $0.desktopReady = false; $0.desktopError = "This ChatGPT application version is not supported yet." })), [.appVersionUnsupported])
        XCTAssertEqual(codes(evaluate(signals(.chatgptApp) { $0.desktopReady = false; $0.desktopError = "Open ChatGPT’s main window." })), [.windowMissingOrAmbiguous])
        let queued = evaluate(signals(.claudeApp), otherDesktopSending: true)
        XCTAssertEqual(queued.readiness, .ready, "A queued desktop send is not a refusal")
        XCTAssertEqual(codes(queued), [.queuedBehindDesktopSend])
        let gemini = evaluate(signals(.geminiApp))
        XCTAssertEqual(gemini.readiness, .unavailable); XCTAssertEqual(codes(gemini), [.notOfferedInBuild])
    }

    func testCLIAndWebhookStates() {
        XCTAssertEqual(evaluate(signals(.codexCLI)).readiness, .ready)
        let signedOut = evaluate(signals(.claudeCode) { $0.snapshotReady = false; $0.accountStatus = .signedOut })
        XCTAssertEqual(signedOut.readiness, .blocked); XCTAssertEqual(codes(signedOut), [.cliSignedOut])
        let missing = evaluate(signals(.codexCLI) { $0.snapshotReady = false; $0.accountStatus = .unknown; $0.snapshotReason = "Install Codex, then sign in with your local account." })
        XCTAssertEqual(missing.readiness, .unavailable); XCTAssertEqual(codes(missing), [.notInstalled])
        let unchecked = evaluate(signals(.codexCLI) { $0.snapshotReady = false; $0.accountStatus = .unknown; $0.snapshotReason = "Not checked"; $0.connected = false })
        XCTAssertEqual(unchecked.readiness, .ready); XCTAssertEqual(codes(unchecked), [.signInUnknown])
        if case .busy = evaluate(signals(.codexCLI) { $0.isSending = true }).readiness {} else { XCTFail("CLI work is busy") }
        XCTAssertEqual(codes(evaluate(signals(.codexCLI) { $0.unresolvedAttemptIDs = ["C1"] })), [.incompleteRequestBlocking])

        let unconfigured = evaluate(signals(.grokbot) { $0.grokBotConfigured = false })
        XCTAssertEqual(unconfigured.readiness, .blocked); XCTAssertEqual(codes(unconfigured), [.webhookNotConfigured])
        let tunnel = evaluate(signals(.grokbot) { $0.grokBotActivity = "Starting reply tunnel…" })
        XCTAssertEqual(tunnel.readiness, .blocked); XCTAssertEqual(codes(tunnel), [.tunnelStarting]); XCTAssertEqual(tunnel.reasons[0].fixOn, .none)
        let cold = evaluate(signals(.grokbot) { $0.snapshotReady = false })
        XCTAssertEqual(cold.readiness, .ready); XCTAssertEqual(codes(cold), [.tunnelStarting])
    }

    func testMessagesStates() {
        let agent = MessagesAgentSignal(agentID: UUID(), gridID: .featuredMessages(.fo), name: "Fo", routable: true, routeStatus: "Connected", selected: true)
        var m = allowed(); m.visibleGridIDs = [agent.gridID]
        let ready = AvailabilityCalculator.availability(agent, inputs: m, now: now)
        XCTAssertEqual(ready.readiness, .ready); XCTAssertEqual(ready.form, .messages); XCTAssertTrue(ready.visibleInGrid); XCTAssertTrue(ready.capabilities.attachments)
        XCTAssertEqual(ready.agentID, "messages:\(agent.agentID.uuidString)"); XCTAssertEqual(RemoteAgentIDs.messagesAgent(ready.agentID), agent.agentID)

        var off = m; off.messagesSendsAllowed = false
        XCTAssertEqual(AvailabilityCalculator.availability(agent, inputs: off, now: now).reasons.map(\.code), [.remoteMessagesOff])
        var noHistory = m; noHistory.fullDiskAccess = .denied; noHistory.databaseAvailable = false
        XCTAssertEqual(AvailabilityCalculator.availability(agent, inputs: noHistory, now: now).reasons.first?.permission, .fullDiskAccess)
        var noDatabase = m; noDatabase.databaseAvailable = false; noDatabase.databaseStatus = "Messages history unavailable"
        XCTAssertEqual(AvailabilityCalculator.availability(agent, inputs: noDatabase, now: now).reasons.map(\.code), [.messagesDatabaseUnavailable])
        var contacts = m; contacts.contacts = .notRequested
        XCTAssertEqual(AvailabilityCalculator.availability(agent, inputs: contacts, now: now).reasons.first?.permission, .contacts,
                       "An unrequested Contacts grant blocks, so a remote send never triggers the Contacts prompt")
        var automation = m; automation.automation = .denied
        XCTAssertEqual(AvailabilityCalculator.availability(agent, inputs: automation, now: now).reasons.first?.permission, .automation)
        var closed = m; closed.automation = .needsMessages
        let opening = AvailabilityCalculator.availability(agent, inputs: closed, now: now)
        XCTAssertEqual(opening.readiness, .ready); XCTAssertEqual(opening.reasons.map(\.code), [.automationNeedsMessagesOpen])
        var unroutable = agent; unroutable.routable = false; unroutable.routeStatus = "No supported conversation found"
        let lost = AvailabilityCalculator.availability(unroutable, inputs: m, now: now)
        XCTAssertEqual(lost.reasons.map(\.code), [.conversationUnroutable]); XCTAssertEqual(lost.reasons[0].detail, "No supported conversation found")
        var busy = m; busy.messagesBusy = true
        if case .busy = AvailabilityCalculator.availability(agent, inputs: busy, now: now).readiness {} else { XCTFail("A Messages send is busy") }
    }

    @MainActor private final class Apps {
        var installation: DesktopAppInstallation
        var opened: [URL] = []
        init(_ installation: DesktopAppInstallation) { self.installation = installation }
        var client: DesktopAppInstallationClient { .init(inspect: { _ in self.installation }, open: { self.opened.append($0) }) }
    }

    func testModelReadsFixtureSessionsWithoutConnectingOrLaunching() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("msgblast-availability-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let web = WebAgents(directory: directory, fixture: true)
        defer { web.beginShutdown() }
        let apps = Apps(.init(url: URL(fileURLWithPath: "/Fixture/Claude.app"), processID: nil))
        let claudeApp = WebAgentSession(provider: .claudeApp, storageURL: directory.appendingPathComponent("claude-app.json"), fixture: true, museApp: .shared, desktopApps: apps.client)
        defer { claudeApp.beginShutdown() }
        claudeApp.setEnabled(true)
        claudeApp.updateState { $0.desktopConversation = .init(name: "Claude") }
        let agent = MessagesAgentSignal(agentID: UUID(), gridID: .messages(UUID()), name: "Cedar", routable: true, routeStatus: "Connected", selected: false)
        var inputs = allowed(); inputs.messagesAgents = [agent]; inputs.visibleGridIDs = [.web(.claudeApp)]
        var probes: [Bool] = []
        let model = AvailabilityModel(sessions: { web.sessions.filter { $0.provider != .claudeApp } + [claudeApp] }, inputs: { inputs }, probe: { slow in probes.append(slow) }, now: { self.now })
        let agents = model.recompute()
        XCTAssertEqual(agents.count, web.sessions.count + 1)
        XCTAssertEqual(Set(agents.map(\.agentID)).count, agents.count, "Agent ids are unique")
        let app = try XCTUnwrap(agents.first { $0.agentID == "claudeApp" })
        XCTAssertTrue(app.visibleInGrid)
        XCTAssertEqual(app.readiness, .readyWillLaunch)
        XCTAssertTrue(apps.opened.isEmpty, "Availability never launches an app")
        XCTAssertFalse(claudeApp.connected, "Availability never connects a session")
        XCTAssertTrue(web.sessions.allSatisfy { !$0.connected }, "Availability never loads website pages")
        XCTAssertEqual(agents.first { $0.agentID == "geminiApp" }?.readiness, .unavailable)
        XCTAssertNotNil(agents.first { $0.agentID == agent.remoteID })

        // Recompute publishes only content changes, not new timestamps.
        var published = 0
        let subscription = model.$agents.dropFirst().sink { _ in published += 1 }
        model.recompute()
        XCTAssertEqual(published, 0)
        apps.installation = .init(url: nil, processID: nil)
        claudeApp.refreshDesktopInstallation()
        model.recompute()
        XCTAssertEqual(published, 1)
        XCTAssertEqual(model.availability(for: "claudeApp")?.reasons.map(\.code), [.notInstalled])
        subscription.cancel()

        // The loop probes immediately (slow cadence first), then stops cleanly.
        model.interval = .milliseconds(20)
        model.start()
        for _ in 0..<100 where probes.count < 3 { try await Task.sleep(for: .milliseconds(10)) }
        model.stop()
        XCTAssertFalse(model.isRunning)
        XCTAssertGreaterThanOrEqual(probes.count, 3)
        XCTAssertEqual(probes.first, true); XCTAssertEqual(probes.dropFirst().first, false)
    }

    func testKeepAwakeFollowsTheClientSendsAndSetting() {
        final class Ledger: @unchecked Sendable { var created = 0; var released = 0; var next: UInt32 = 1 }
        let ledger = Ledger()
        let keepAwake = RemoteKeepAwake(settingEnabled: true, assertions: .init(create: { _ in ledger.created += 1; ledger.next += 1; return ledger.next }, release: { _ in ledger.released += 1 }))
        keepAwake.setClient(connected: true)
        XCTAssertFalse(keepAwake.held, "Connecting alone does not hold the Mac awake; the phone asks")
        XCTAssertTrue(keepAwake.setClientRequested(true))
        XCTAssertTrue(keepAwake.held)
        keepAwake.beginSend()
        XCTAssertEqual(ledger.created, 1, "One assertion at a time")
        keepAwake.setClient(connected: false)
        XCTAssertTrue(keepAwake.held, "A running send keeps the assertion after a disconnect")
        keepAwake.endSend()
        XCTAssertFalse(keepAwake.held)
        XCTAssertEqual(ledger.released, 1)

        keepAwake.setSettingEnabled(false)
        keepAwake.setClient(connected: true)
        XCTAssertFalse(keepAwake.setClientRequested(true), "The Mac setting refuses the phone's request")
        keepAwake.beginSend()
        XCTAssertFalse(keepAwake.held, "Turning the setting off disables send assertions too")
        keepAwake.endSend()
        XCTAssertEqual(ledger.created, 1)
    }

    func testPowerStateAndSettingsPersistence() throws {
        var locked = false
        let power = MacPowerState(readLocked: { locked }, observe: false)
        XCTAssertFalse(power.locked)
        locked = true; power.refresh()
        XCTAssertTrue(power.locked)
        power.simulate(displaysAsleep: true)
        XCTAssertFalse(power.awake)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("msgblast-remote-settings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (defaults, error) = RemoteSettings.load(directory: directory)
        XCTAssertNil(error)
        XCTAssertFalse(defaults.enabled, "Remote control is off until the user turns it on")
        XCTAssertFalse(defaults.allowMessagesSends, "iMessage sends from the phone are off by default")
        XCTAssertTrue(defaults.keepAwake)
        var changed = defaults; changed.enabled = true; changed.bindPolicy = .tailscaleAndLAN; changed.port = 51000
        try changed.save(directory: directory)
        XCTAssertEqual(RemoteSettings.load(directory: directory).0, changed)
        XCTAssertEqual(try JSONDecoder().decode(RemoteSettings.self, from: Data(#"{"bindPolicy":"future"}"#.utf8)).bindPolicy, .automatic)
    }
}
