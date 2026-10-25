import XCTest
@testable import msgblastCore

final class OnboardingTests: XCTestCase {
    func testLegacyAppsOnlyPermissionRecordDropsHiddenMessagesChoiceWithoutDeletingAgents() throws {
        let agentID = UUID()
        var setup = OnboardingState()
        setup.selected = [.wabi, .otherMessages]
        setup.messageAgentIDs = ["otherMessages": agentID]
        setup.discoveredMessageAgentIDs = [agentID]
        setup.permissionsCompleted = true
        setup.revalidatePermissionSections([.apps])
        let restored = try JSONDecoder().decode(OnboardingState.self, from: JSONEncoder().encode(setup))
        XCTAssertEqual(restored.selected, [.wabi], "An invisible legacy choice must not disable Continue")
        XCTAssertEqual(restored.messageAgentIDs["otherMessages"], agentID)
        XCTAssertEqual(restored.discoveredMessageAgentIDs, [agentID])
    }

    func testRefreshingSavedAppsOnlyPermissionsRemovesHiddenPrerequisiteWithoutRewindingSetup() {
        var setup = OnboardingState()
        setup.completePermissions(messaging: true, apps: true)
        setup.selected = [.wabi, .otherMessages]
        setup.completed = [.wabi]
        setup.revalidatePermissionSections([.apps])
        XCTAssertEqual(setup.selected, [.wabi])
        XCTAssertEqual(setup.completed, [.wabi])
        XCTAssertEqual(setup.stage, .choosing)
        XCTAssertEqual(setup.permissionsCompleted, true)
        XCTAssertEqual(setup.approvedPermissionSections, [.apps])
    }

    func testOnboardingOffersNativeAppsAndRetainsLegacyWebCheckpoints() throws {
        let offered = Set(OnboardingChoice.offeredChoices)
        for choice: OnboardingChoice in [.muse, .chatgpt, .claude, .dots, .grok, .grokbot, .geminiApp] { XCTAssertFalse(offered.contains(choice)) }
        for choice: OnboardingChoice in [.museApp, .chatgptApp, .claudeApp, .dotsApp, .grokBotApp, .wabi, .hark, .os3] { XCTAssertTrue(offered.contains(choice)) }
        var saved = OnboardingState()
        saved.selected = [.chatgpt, .muse, .grokbot]
        saved.completed = [.muse]
        let restored = try JSONDecoder().decode(OnboardingState.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(restored.selected, [.chatgpt, .muse, .grokbot])
        XCTAssertEqual(restored.pendingChoices, [.chatgpt, .grokbot], "An existing setup checkpoint must remain resumable")
    }

    func testDeferredGeminiCheckpointSurvivesWithoutBlockingOtherAppConnections() throws {
        var saved = OnboardingState()
        saved.selected = [.geminiApp, .wabi]
        saved.stage = .connecting
        let reopened = try JSONDecoder().decode(OnboardingState.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(reopened.selected, saved.selected)
        XCTAssertEqual(reopened.pendingChoices, [.wabi])
        XCTAssertEqual(reopened.pendingSteps, [.agent(.wabi)])
        XCTAssertFalse(WebProvider.desktopProviders.contains(.geminiApp))
        XCTAssertEqual(reopened.availableSelected, [.wabi])
        saved.selected = [.geminiApp]; saved.completed = [.geminiApp]; saved.stage = .choosing
        saved.begin()
        XCTAssertFalse(saved.hasConnectedAgent, "A deferred saved completion cannot count as a working agent")
        XCTAssertEqual(saved.stage, .choosing)
        saved.selected.insert(.wabi)
        saved.begin()
        XCTAssertEqual(saved.stage, .connecting)
        XCTAssertEqual(saved.currentStep, .agent(.wabi))
        XCTAssertTrue(saved.selected.contains(.geminiApp), "Do not erase the saved selection")
    }

    func testDeferredFinalConnectionReconcilesWithoutErasingSavedChoices() throws {
        for connected: Set<OnboardingChoice> in [[], [.wabi]] {
            var saved = OnboardingState()
            saved.completePermissions(messaging: true, apps: true)
            saved.selected = connected.union([.geminiApp])
            saved.completed = connected
            saved.stage = .connecting
            var reopened = try JSONDecoder().decode(OnboardingState.self, from: JSONEncoder().encode(saved))
            reopened.reconcileBuildAvailability()
            XCTAssertEqual(reopened.stage, connected.isEmpty ? .choosing : .feedback)
            var expected = saved
            expected.stage = reopened.stage
            XCTAssertEqual(reopened, expected, "Only the empty active checkpoint may change")
            reopened.reconcileBuildAvailability()
            XCTAssertEqual(reopened, expected)
        }
    }

    func testDeferredChoiceDoesNotRewindPendingOrFinishedSetup() {
        for stage: OnboardingState.Stage in [.choosing, .importing, .connecting, .feedback, .finished] {
            var saved = OnboardingState()
            saved.selected = [.geminiApp, .wabi]
            saved.stage = stage
            var reopened = saved
            reopened.reconcileBuildAvailability()
            XCTAssertEqual(reopened, saved, "Pending Wabi or an unrelated checkpoint must remain intact")
        }
    }

    func testAutomaticMessagesCheckpointRetainsOptOutAcrossPermissionRestart() throws {
        var setup = OnboardingState()
        let id = UUID()
        setup.selected = [.fo]
        setup.completed = [.fo]
        setup.messageAgentIDs = ["fo": id]
        setup.discoveredMessageAgentIDs = [id]
        setup.messagesAutomaticallyAdded = true
        setup.excludeDiscoveredMessageAgent(id, agents: [], availableIDs: [])
        setup.preparePermissionChange()
        var restored = try JSONDecoder().decode(OnboardingState.self, from: JSONEncoder().encode(setup))
        restored.completePermissions(messaging: true, apps: true)
        XCTAssertEqual(restored.messagesAutomaticallyAdded, true)
        XCTAssertTrue(restored.selected.isEmpty)
        XCTAssertTrue(restored.selectedMessageAgentIDs.isEmpty)
        XCTAssertEqual(restored.excludedDiscoveredMessageAgentIDs, [id])
    }

    func testPermissionGateRequiresAllFiveGrantsAndBundledAppControl() {
        // Cover all combinations: grants split across incomplete sections must not unlock setup.
        for mask in 0..<64 {
            let granted = (0..<6).map { mask & (1 << $0) != 0 }
            let readiness = OnboardingPermissionReadiness(
                fullDiskAccess: granted[0], contacts: granted[1], automation: granted[2],
                hostAccessibility: granted[3], screenCapture: granted[4], driverInstalled: granted[5])
            let messagingReady = mask & 0b0000111 == 0b0000111
            let appsReady = mask & 0b111000 == 0b111000
            XCTAssertEqual(readiness.messagingReady, messagingReady, "Grants mask: \(mask)")
            XCTAssertEqual(readiness.appsReady, appsReady, "Grants mask: \(mask)")
            XCTAssertEqual(readiness.canContinue, messagingReady && appsReady, "Grants mask: \(mask)")
            var sections: Set<OnboardingPermissionSection> = []
            if messagingReady { sections.insert(.messaging) }
            if appsReady { sections.insert(.apps) }
            XCTAssertEqual(readiness.completedSections, sections, "Grants mask: \(mask)")
        }
    }

    func testPermissionCompletionRejectsPartialSetupAndRecordsOnlyCompleteSections() throws {
        for (messaging, apps, sections): (Bool, Bool, Set<OnboardingPermissionSection>) in [
            (false, false, []), (true, false, [.messaging]),
            (false, true, [.apps]), (true, true, [.messaging, .apps])
        ] {
            var setup = OnboardingState()
            setup.chooseConnector(.messages)
            setup.selected = [.fo, .chatgptApp]
            setup.completed = [.fo]
            setup.skipped = [.chatgptApp]
            let before = setup
            XCTAssertEqual(setup.completePermissions(messaging: messaging, apps: apps), messaging && apps)
            if !messaging || !apps {
                XCTAssertEqual(setup, before, "Any missing permission must not advance or replace saved setup")
            } else {
                XCTAssertFalse(setup.needsPermissionSetup)
                XCTAssertEqual(setup.approvedPermissionSections, sections)
                XCTAssertNil(setup.connector)
                XCTAssertEqual(setup.connectorStartCompleted, true)
                XCTAssertEqual(setup.prerequisitesCompleted, true)
                XCTAssertEqual(setup.messagesDiscoveryReviewed, true)
                XCTAssertEqual(setup.selected, before.selected)
                XCTAssertEqual(setup.completed, before.completed)
                XCTAssertEqual(setup.skipped, before.skipped)
                XCTAssertEqual(setup.stage, before.stage)
                let restored = try JSONDecoder().decode(OnboardingState.self, from: JSONEncoder().encode(setup))
                XCTAssertEqual(restored, setup)
            }
        }
    }

    func testPermissionHandoffSurvivesRestartWithoutLosingActiveSetup() throws {
        for stage: OnboardingState.Stage in [.choosing, .importing, .connecting, .feedback, .finished] {
            var setup = OnboardingState()
            setup.selected = [.fo, .chatgptApp, .claudeApp]
            setup.completed = [.chatgptApp]
            setup.skipped = [.claudeApp]
            setup.messageAgentIDs = [OnboardingChoice.fo.rawValue: UUID()]
            setup.discoveredMessageAgentIDs = [UUID()]
            setup.excludedDiscoveredMessageAgentIDs = [UUID()]
            setup.messagesDiscoveryReviewed = false
            setup.stage = stage
            setup.completePermissions(messaging: true, apps: true)
            XCTAssertEqual(setup.messagesDiscoveryReviewed, stage == .choosing,
                           "Permission completion must not dismiss an active discovery step")
            let beforeHandoff = setup
            setup.preparePermissionChange()
            var restored = try JSONDecoder().decode(OnboardingState.self, from: JSONEncoder().encode(setup))
            XCTAssertTrue(restored.needsPermissionSetup)
            XCTAssertEqual(restored.approvedPermissionSections, [.messaging, .apps], "Saved section choices are not current OS grants")
            var expected = beforeHandoff
            expected.permissionsCompleted = false
            XCTAssertEqual(restored, expected, "A restart must retain every choice, ID, and active stage")
            restored.completePermissions(messaging: true, apps: true)
            XCTAssertEqual(restored.stage, stage)
            XCTAssertEqual(restored.selected, beforeHandoff.selected)
            XCTAssertEqual(restored.completed, beforeHandoff.completed)
            XCTAssertEqual(restored.skipped, beforeHandoff.skipped)
            XCTAssertEqual(restored.messageAgentIDs, beforeHandoff.messageAgentIDs)
            XCTAssertEqual(restored.discoveredMessageAgentIDs, beforeHandoff.discoveredMessageAgentIDs)
            XCTAssertEqual(restored.excludedDiscoveredMessageAgentIDs, beforeHandoff.excludedDiscoveredMessageAgentIDs)
        }
    }

    func testExplicitPermissionSkipSurvivesRestartWithoutClaimingMissingGrants() throws {
        for stage: OnboardingState.Stage in [.choosing, .importing, .connecting, .feedback, .finished] {
            var setup = OnboardingState()
            setup.stage = stage
            setup.selected = [.chatgptApp, .otherMessages]
            setup.completed = [.chatgptApp]
            setup.messageAgentIDs["otherMessages"] = UUID()
            setup.skipPermissions(messaging: false, apps: true)
            var restored = try JSONDecoder().decode(OnboardingState.self, from: JSONEncoder().encode(setup))
            XCTAssertFalse(restored.needsPermissionSetup)
            XCTAssertEqual(restored.permissionsSkipped, true)
            XCTAssertEqual(restored.approvedPermissionSections, [.apps], "Skipping must never claim a missing Messages grant")
            XCTAssertEqual(restored.selected, stage == .finished ? [.chatgptApp, .otherMessages] : [.chatgptApp])
            XCTAssertEqual(restored.completed, [.chatgptApp])
            XCTAssertEqual(restored.messageAgentIDs, setup.messageAgentIDs)
            restored.preparePermissionChange()
            XCTAssertTrue(restored.needsPermissionSetup)
            XCTAssertEqual(restored.permissionsSkipped, false, "An explicit retry must resume access after another restart")
            XCTAssertEqual(restored.selected, setup.selected)
            XCTAssertEqual(restored.stage, stage)
        }
    }

    func testLegacyUnfinishedSetupRequiresPermissionCheckAndKeepsItsPendingStep() throws {
        let messageID = UUID()
        let object: [String: Any] = [
            "selected": ["chatgptApp", "fo"], "completed": ["chatgptApp"], "skipped": [],
            "messageAgentIDs": ["fo": messageID.uuidString], "stage": "connecting"
        ]
        let restored = try JSONDecoder().decode(OnboardingState.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(restored.permissionsCompleted)
        XCTAssertNil(restored.permissionsSkipped)
        XCTAssertNil(restored.approvedPermissionSections)
        XCTAssertTrue(restored.needsPermissionSetup)
        XCTAssertEqual(restored.stage, .connecting)
        XCTAssertEqual(restored.currentStep, .messages)
        XCTAssertEqual(restored.messageAgentIDs["fo"], messageID)
    }

    func testPermissionSkipKeepsAnUnfinishedAppConnection() throws {
        var setup = OnboardingState()
        setup.selected = [.chatgptApp, .claudeApp]
        setup.completed = [.chatgptApp]
        setup.stage = .connecting
        XCTAssertEqual(setup.currentStep, .agent(.claudeApp))
        setup.skipPermissions(messaging: false, apps: true)
        let restored = try JSONDecoder().decode(OnboardingState.self, from: JSONEncoder().encode(setup))
        XCTAssertEqual(restored.currentStep, .agent(.claudeApp))
        XCTAssertEqual(restored.stage, .connecting)
        XCTAssertEqual(restored.completed, [.chatgptApp])
        XCTAssertFalse(restored.needsPermissionSetup)
        XCTAssertEqual(restored.permissionsSkipped, true)
    }

    func testResumingCompletedOnboardingRequiresFreshPermissionChecks() {
        var setup = OnboardingState()
        setup.selected = [.chatgptApp]
        setup.completed = [.chatgptApp]
        setup.completePermissions(messaging: true, apps: true)
        setup.stage = .finished
        setup.resume()
        XCTAssertTrue(setup.needsPermissionSetup)
        XCTAssertEqual(setup.approvedPermissionSections, [.messaging, .apps])
        XCTAssertEqual(setup.selected, [.chatgptApp])
        XCTAssertEqual(setup.completed, [.chatgptApp])
        XCTAssertEqual(setup.stage, .choosing)
    }

    func testMessagesReviewPreservesConnectionsAndReturnsToContactList() throws {
        var setup = OnboardingState()
        setup.chooseConnector(.messages)
        setup.selected = [.fo, .otherMessages]
        setup.completed = [.fo]
        setup.skipped = [.otherMessages]
        setup.stage = .finished
        setup.messagesDiscoveryReviewed = true
        setup.reviewMessages(prerequisitesReady: true)
        let restored = try JSONDecoder().decode(OnboardingState.self, from: JSONEncoder().encode(setup))
        XCTAssertEqual(restored.messagesDiscoveryReviewed, false)
        XCTAssertEqual(restored.prerequisitesCompleted, true)
        XCTAssertEqual(restored.completed, [.fo])
        setup.messagesDiscoveryReviewed = true
        setup.stage = .feedback
        setup.chooseAgain()
        XCTAssertEqual(setup.messagesDiscoveryReviewed, false, "Failed final readiness must return to contacts, never an empty chooser")
        setup.resume()
        XCTAssertEqual(setup.connectorStartCompleted, false, "General resume must never open the empty Messages chooser")
        XCTAssertEqual(setup.completed, [.fo])
    }

    func testReminderUsesActualContactsAndIgnoresConnectedOrDeselectedRows() {
        let fo = Agent(contactID: "fo", name: "Fo", handles: ["fo@example.test"])
        let tiny = Agent(contactID: "tiny", name: "tinyNature", handles: ["tiny@example.test"])
        var setup = OnboardingState()
        setup.selected = [.fo, .otherMessages]
        setup.skipped = [.otherMessages]
        setup.messageAgentIDs = ["fo": fo.id, "otherMessages": fo.id]
        setup.discoveredMessageAgentIDs = [fo.id, tiny.id]
        let chats = [Chat(id: "fo-chat", handle: fo.handles[0], lastActivity: 1)]
        XCTAssertEqual(setup.unresolvedMessageAgents(in: [fo, tiny], chats: chats).map(\.name), ["tinyNature"])
        setup.excludedDiscoveredMessageAgentIDs = [tiny.id]
        XCTAssertTrue(setup.unresolvedMessageAgents(in: [fo, tiny], chats: chats).isEmpty, "Stale Other Messages skip for connected Fo is not an unresolved agent")
        setup.excludedDiscoveredMessageAgentIDs = []
        XCTAssertTrue(setup.unresolvedMessageAgents(in: [fo, tiny], chats: chats + [Chat(id: "tiny-chat", handle: tiny.handles[0], lastActivity: 2)]).isEmpty)
    }

    func testOldSkippedChoicesDoNotRemindAboutUnselectedRecipients() {
        let tiny = Agent(contactID: "tiny", name: "tinyNature", handles: ["tiny@example.test"])
        var setup = OnboardingState()
        setup.selected = [.geminiApp, .otherMessages]
        setup.skipped = setup.selected
        setup.discoveredMessageAgentIDs = [tiny.id]
        XCTAssertTrue(setup.connectionReminderChoices(selectedProviders: []).isEmpty)
        XCTAssertTrue(setup.connectionReminderChoices(selectedProviders: [.geminiApp]).isEmpty)
        XCTAssertTrue(setup.unresolvedMessageAgents(in: [tiny], chats: [], selectedIDs: []).isEmpty)
        XCTAssertEqual(setup.unresolvedMessageAgents(in: [tiny], chats: [], selectedIDs: [tiny.id]).map(\.name), ["tinyNature"])
    }

    func testDeselectingRepresentativeKeepsOnlySameCategoryReplacement() throws {
        let first = Agent(contactID: "first", name: "Fo", handles: ["first@example.test"])
        let second = Agent(contactID: "second", name: "Fo", handles: ["second@example.test"])
        let tiny = Agent(contactID: "tiny", name: "tinyNature", handles: ["tiny@example.test"])
        var setup = OnboardingState()
        setup.selected = [.fo, .otherMessages]; setup.completed = [.fo, .otherMessages]
        setup.messageAgentIDs = ["fo": second.id, "otherMessages": tiny.id]
        setup.discoveredMessageAgentIDs = [first.id, second.id, tiny.id]
        setup.excludeDiscoveredMessageAgent(second.id, agents: [first, second, tiny], availableIDs: [first.id, second.id, tiny.id])
        XCTAssertEqual(setup.messageAgentIDs["fo"], first.id)
        XCTAssertTrue(setup.completed.contains(.fo))
        XCTAssertTrue(setup.selectedMessageAgentIDs.contains(first.id))
        setup.excludeDiscoveredMessageAgent(tiny.id, agents: [first, second, tiny], availableIDs: [first.id])
        XCTAssertNil(setup.messageAgentIDs["otherMessages"], "Other Messages must not steal a Fo contact as its representative")
        XCTAssertEqual(setup.selected, [.fo])
        let restored = try JSONDecoder().decode(OnboardingState.self, from: JSONEncoder().encode(setup))
        XCTAssertEqual(restored.selectedMessageAgentIDs, [first.id])
    }
    func testConnectorStartPersistsAndRoutesEachCategory() throws {
        for connector in OnboardingConnector.allCases {
            var setup = OnboardingState()
            XCTAssertEqual(setup.connectorStartCompleted, false)
            setup.chooseConnector(connector)
            let restored = try JSONDecoder().decode(OnboardingState.self, from: JSONEncoder().encode(setup))
            XCTAssertEqual(restored.connector, connector)
            XCTAssertEqual(restored.connectorStartCompleted, true)
            XCTAssertEqual(restored.prerequisitesCompleted, connector != .messages)
            XCTAssertEqual(restored.messagesDiscoveryReviewed, connector != .messages)
        }
        XCTAssertTrue(OnboardingConnector.apps.includes(.grokbot))
        XCTAssertFalse(OnboardingConnector.apps.includes(.codexCLI))
        XCTAssertTrue(OnboardingConnector.clis.includes(.codexCLI))
        XCTAssertTrue(OnboardingConnector.clis.includes(.hermes))
        XCTAssertFalse(OnboardingConnector.clis.includes(.chatgpt))
    }

    func testDiscoveryReviewDoesNotRepeatMessagesSelection() throws {
        var setup = OnboardingState()
        setup.selected = [.fo, .szn, .chatgpt]
        setup.completed = [.fo]
        setup.reviewMessagesDiscovery()
        setup.begin(); setup.beginConnections()
        XCTAssertEqual(setup.pendingSteps, [.agent(.chatgpt)])
        setup.complete(.chatgpt)
        XCTAssertEqual(setup.stage, .feedback)
        let restored = try JSONDecoder().decode(OnboardingState.self, from: JSONEncoder().encode(setup))
        XCTAssertTrue(restored.pendingSteps.isEmpty)
        XCTAssertEqual(restored.completed, [.fo, .chatgpt])
        XCTAssertEqual(restored.skipped, [.szn])
    }

    func testChecklistAndConnectionsSurvivePermissionRestart() throws {
        var setup = OnboardingState()
        XCTAssertEqual(setup.prerequisitesCompleted, false)
        setup.prerequisitesCompleted = true
        setup.toggle(.chatgpt)
        setup.toggle(.fo)
        setup.begin(); setup.beginConnections(); setup.complete(.chatgpt)
        setup.prerequisitesCompleted = false
        let restored = try JSONDecoder().decode(OnboardingState.self, from: JSONEncoder().encode(setup))
        XCTAssertEqual(restored.prerequisitesCompleted, false)
        XCTAssertEqual(restored.completed, [.chatgpt])
        XCTAssertEqual(restored.currentStep, .messages)
        XCTAssertTrue(restored.pendingWebProviders.isEmpty)
    }

    func testOlderSetupDoesNotAcquireANewChecklist() throws {
        let data = Data(#"{"selected":[],"completed":[],"skipped":[],"messageAgentIDs":{},"stage":"choosing"}"#.utf8)
        let restored = try JSONDecoder().decode(OnboardingState.self, from: data)
        XCTAssertNil(restored.prerequisitesCompleted)
        XCTAssertNil(restored.connectorStartCompleted)
    }

    func testHarkAndPokeUseSeparateSetupPathsAndRestoreProgress() throws {
        var setup = OnboardingState()
        setup.toggle(.hark)
        setup.toggle(.poke)
        setup.begin()
        XCTAssertEqual(setup.pendingWebProviders, [.hark])
        setup.beginConnections()
        XCTAssertEqual(setup.pendingSteps, [.agent(.hark), .messages])
        setup.complete(.hark)
        setup.confirmMessages(connected: [.poke], skipped: [])
        XCTAssertEqual(setup.stage, .feedback)
        let restored = try JSONDecoder().decode(OnboardingState.self, from: JSONEncoder().encode(setup))
        XCTAssertEqual(restored.completed, [.hark, .poke])
        let contacts = [Agent(contactID: "poke", name: "Poke 🌴", handles: ["poke@example.com"]),
                        Agent(contactID: "other", name: "Pokemon", handles: ["other@example.com"]),
                        Agent(contactID: "person", name: "Alex Poke", handles: ["person@example.com"])]
        XCTAssertEqual(OnboardingChoice.poke.contactSuggestions(in: contacts).map(\.contactID), ["poke"])
        XCTAssertTrue(KnownAgentContacts(agents: []).contains(name: "Poke"))
    }

    func testRabbitWebsiteSetupCanCompleteWithoutMessagesAccess() throws {
        var onboarding = OnboardingState()
        onboarding.toggle(.os3)
        onboarding.begin()
        XCTAssertEqual(onboarding.pendingWebProviders, [.os3])
        onboarding.beginConnections()
        XCTAssertEqual(onboarding.currentStep, .agent(.os3))
        onboarding.complete(.os3)
        XCTAssertEqual(onboarding.stage, .feedback)
        onboarding.finish()
        let restored = try JSONDecoder().decode(OnboardingState.self, from: JSONEncoder().encode(onboarding))
        XCTAssertTrue(restored.isFinished)
        XCTAssertEqual(restored.selected, [.os3])
        XCTAssertEqual(restored.completed, [.os3])
    }

    func testWebsiteSelectionOffersBrowserImportBeforeProviderSignIn() {
        var onboarding = OnboardingState()
        onboarding.toggle(.chatgpt)
        onboarding.toggle(.fo)
        onboarding.begin()
        XCTAssertEqual(onboarding.stage.rawValue, "importing")
        XCTAssertTrue(onboarding.completed.isEmpty, "Offering import must not claim an account is connected")
    }

    func testSkippingBrowserImportRetainsEveryWebsiteForManualSignIn() throws {
        var onboarding = OnboardingState()
        for choice: OnboardingChoice in [.chatgpt, .claude, .grokbot, .codexCLI] { onboarding.toggle(choice) }
        onboarding.begin()
        XCTAssertEqual(onboarding.pendingWebProviders, [.chatgpt, .claude])
        let restored = try JSONDecoder().decode(OnboardingState.self, from: JSONEncoder().encode(onboarding))
        XCTAssertEqual(restored.stage, .importing)
        XCTAssertEqual(restored.selected, onboarding.selected)
        onboarding.beginConnections()
        XCTAssertEqual(onboarding.stage, .connecting)
        XCTAssertTrue(onboarding.skipped.isEmpty)
        XCTAssertEqual(onboarding.pendingSteps, [.agent(.chatgpt), .agent(.claude), .agent(.grokbot), .agent(.codexCLI)])
    }

    func testNativeOnlyChoicesDoNotOfferBrowserImport() {
        var onboarding = OnboardingState()
        for choice: OnboardingChoice in [.grokbot, .claudeCode, .fo] { onboarding.toggle(choice) }
        onboarding.begin()
        XCTAssertEqual(onboarding.stage, .connecting)
        XCTAssertTrue(onboarding.pendingWebProviders.isEmpty)
    }

    func testReturningToSetupDoesNotImportCompletedWebsiteAccountsAgain() {
        var onboarding = OnboardingState()
        onboarding.toggle(.chatgpt)
        onboarding.toggle(.fo)
        onboarding.begin()
        onboarding.beginConnections()
        onboarding.complete(.chatgpt)
        onboarding.chooseAgain()
        onboarding.begin()
        XCTAssertEqual(onboarding.stage, .connecting)
        XCTAssertEqual(onboarding.currentStep, .messages)
        XCTAssertTrue(onboarding.pendingWebProviders.isEmpty)
    }

    func testEmptyMessagesConfirmationClearsOldRowsWhileAnotherProviderPermitsFinish() {
        var onboarding = OnboardingState()
        for choice: OnboardingChoice in [.chatgpt, .fo, .szn] { onboarding.toggle(choice) }
        onboarding.begin(); onboarding.beginConnections()
        onboarding.complete(.chatgpt)
        onboarding.confirmMessages(connected: [.fo], skipped: [])
        XCTAssertEqual(onboarding.currentStep, .messages)
        onboarding.confirmMessages(connected: [], skipped: [.fo, .szn])
        XCTAssertEqual(onboarding.completed, [.chatgpt])
        XCTAssertEqual(onboarding.skipped, [.fo, .szn])
        onboarding.finish()
        XCTAssertTrue(onboarding.isFinished)
        XCTAssertFalse(onboarding.completed.contains(where: \.isMessages))
    }

    func testMessagesConfirmationConnectsOnlySelectedRowsAndSkipsTheRest() {
        var onboarding = OnboardingState()
        for choice: OnboardingChoice in [.instinct, .fo, .szn] { onboarding.toggle(choice) }
        onboarding.begin(); onboarding.beginConnections()
        onboarding.confirmMessages(connected: [.instinct, .fo], skipped: [.szn])
        XCTAssertEqual(onboarding.completed, [.instinct, .fo])
        XCTAssertEqual(onboarding.skipped, [.szn])
        XCTAssertEqual(onboarding.stage, .feedback)
        XCTAssertFalse(onboarding.isFinished)
    }

    func testMessagesConfirmationKeepsMissingConversationsPending() {
        var onboarding = OnboardingState()
        for choice: OnboardingChoice in [.fo, .szn, .otherMessages] { onboarding.toggle(choice) }
        onboarding.begin(); onboarding.beginConnections()
        onboarding.confirmMessages(connected: [.fo], skipped: [.otherMessages])
        XCTAssertEqual(onboarding.pendingChoices, [.szn])
        XCTAssertEqual(onboarding.currentStep, .messages)
        XCTAssertEqual(onboarding.stage, .connecting)
        onboarding.confirmMessages(connected: [], skipped: [.fo, .szn, .otherMessages])
        XCTAssertTrue(onboarding.completed.isEmpty, "Unchecking a previously confirmed row removes it from connected choices")
        XCTAssertEqual(onboarding.stage, .choosing, "Skipping every choice cannot open an empty workspace")
    }

    func testMessagesConfirmationDoesNotCompleteUnselectedOrNonMessagesChoices() {
        var onboarding = OnboardingState()
        onboarding.toggle(.fo)
        onboarding.toggle(.chatgpt)
        onboarding.begin(); onboarding.beginConnections()
        onboarding.confirmMessages(connected: [.fo, .szn, .chatgpt], skipped: [])
        XCTAssertTrue(onboarding.completed.isEmpty, "The provider step must finish first")
        onboarding.complete(.chatgpt)
        onboarding.confirmMessages(connected: [.fo, .szn, .chatgpt], skipped: [.fo])
        XCTAssertEqual(onboarding.completed, [.fo, .chatgpt])
        XCTAssertTrue(onboarding.skipped.isEmpty, "Connected rows take precedence")
        XCTAssertEqual(onboarding.stage, .feedback)
    }

    func testMessagesSuggestionsRequireAnExactSavedContactWithAnAddress() {
        let exact = Agent(contactID: "exact", name: "  fO  ", handles: ["fo@example.test"])
        let duplicate = Agent(contactID: "duplicate", name: "Fo", handles: ["second@example.test"])
        let contacts = [exact, duplicate,
                        Agent(contactID: "partial", name: "Fortune", handles: ["partial@example.test"]),
                        Agent(contactID: "suffix", name: "Fo AI", handles: ["suffix@example.test"]),
                        Agent(name: "Fo", handles: ["manual@example.test"]),
                        Agent(contactID: "empty", name: "Fo", handles: [])]
        XCTAssertEqual(OnboardingChoice.fo.contactSuggestions(in: contacts), [exact, duplicate], "Keep ambiguous exact matches for the user to confirm")
        XCTAssertTrue(OnboardingChoice.instinct.contactSuggestions(in: contacts).isEmpty)
        XCTAssertTrue(OnboardingChoice.szn.contactSuggestions(in: contacts).isEmpty)
        XCTAssertTrue(OnboardingChoice.otherMessages.contactSuggestions(in: contacts).isEmpty)
        XCTAssertTrue(OnboardingChoice.chatgpt.contactSuggestions(in: contacts).isEmpty)
    }

    func testResolvedSetupWaitsForFinalAcknowledgement() {
        var onboarding = OnboardingState()
        onboarding.toggle(.chatgpt)
        onboarding.begin(); onboarding.beginConnections()
        onboarding.complete(.chatgpt)
        XCTAssertTrue(onboarding.hasConnectedAgent)
        XCTAssertTrue(onboarding.pendingSteps.isEmpty)
        XCTAssertEqual(onboarding.stage, .feedback)
        XCTAssertFalse(onboarding.isFinished)
        onboarding.finish()
        XCTAssertTrue(onboarding.isFinished)
    }

    func testMixedSelectionHasOrderedAgentStepsAndOneMessagesStep() {
        var onboarding = OnboardingState()
        for choice: OnboardingChoice in [.szn, .claudeCode, .fo, .chatgpt, .instinct, .grokbot, .otherMessages] {
            onboarding.toggle(choice)
        }
        onboarding.begin(); onboarding.beginConnections()

        XCTAssertEqual(onboarding.pendingSteps, [.agent(.chatgpt), .agent(.grokbot), .agent(.claudeCode), .messages])
        XCTAssertEqual(onboarding.currentStep, .agent(.chatgpt))
        XCTAssertEqual(onboarding.pendingChoices, [.chatgpt, .grokbot, .instinct, .fo, .szn, .claudeCode, .otherMessages])
        XCTAssertEqual(onboarding.stage, .connecting)
    }

    func testMessagesCompletionAndIndividualSkipKeepTheGroupUntilResolved() {
        var onboarding = OnboardingState()
        for choice: OnboardingChoice in [.instinct, .fo, .szn] { onboarding.toggle(choice) }
        onboarding.begin(); onboarding.beginConnections()
        onboarding.complete(.fo)
        onboarding.skip(.instinct)

        XCTAssertEqual(onboarding.currentStep, .messages)
        XCTAssertEqual(onboarding.pendingChoices, [.szn])
        XCTAssertFalse(onboarding.isFinished)

        onboarding.skipCurrentStep()
        XCTAssertEqual(onboarding.stage, .feedback)
        onboarding.finish()
        XCTAssertTrue(onboarding.isFinished)
        XCTAssertEqual(onboarding.completed, [.fo])
        XCTAssertEqual(onboarding.skipped, [.instinct, .szn])
        XCTAssertNil(onboarding.currentStep)
    }

    func testSavedSetupResumesWithTheSamePendingTask() throws {
        var onboarding = OnboardingState()
        for choice: OnboardingChoice in [.chatgpt, .grokbot, .fo] { onboarding.toggle(choice) }
        onboarding.begin(); onboarding.beginConnections()
        onboarding.complete(.chatgpt)
        onboarding.skip(.grokbot)
        onboarding.messageAgentIDs[OnboardingChoice.fo.rawValue] = UUID()
        let restored = try JSONDecoder().decode(OnboardingState.self, from: JSONEncoder().encode(onboarding))

        XCTAssertEqual(restored, onboarding)
        XCTAssertEqual(restored.currentStep, .messages)
        XCTAssertEqual(restored.pendingChoices, [.fo])

        var resumed = restored
        resumed.resume()
        XCTAssertEqual(resumed.stage, .choosing)
        XCTAssertEqual(resumed.selected, onboarding.selected)
        XCTAssertEqual(resumed.completed, [.chatgpt])
        XCTAssertEqual(resumed.messageAgentIDs, onboarding.messageAgentIDs)
        XCTAssertTrue(resumed.skipped.isEmpty)
        XCTAssertEqual(resumed.pendingSteps, [.agent(.grokbot), .messages])
        resumed.begin(); resumed.beginConnections()
        XCTAssertEqual(resumed.currentStep, .agent(.grokbot))
    }

    func testLegacyAppStateHasNoOnboardingAndPreservesDraftAndSelection() throws {
        let agentID = UUID()
        let legacy: [String: Any] = [
            "version": 1,
            "agents": [],
            "comparisons": [],
            "draft": "Keep this draft",
            "selection": [agentID.uuidString],
            "frames": [:]
        ]
        let restored = try JSONDecoder().decode(AppState.self, from: JSONSerialization.data(withJSONObject: legacy))

        XCTAssertNil(restored.onboarding)
        XCTAssertEqual(restored.draft, "Keep this draft")
        XCTAssertEqual(restored.selection, [agentID])
    }

    func testAppStateRoundTripKeepsOnboardingAlongsideExistingData() throws {
        let agent = Agent(name: "Fo", handles: ["fixture@example.test"])
        let chat = Chat(id: "fixture-chat", handle: "fixture@example.test", lastActivity: 0)
        var state = AppState()
        state.agents = [agent]
        state.selection = [agent.id]
        state.draft = "An unsent question"
        state.comparisons = [Comparison(prompt: "An earlier question", members: [Member(agentID: agent.id, name: agent.name, chat: chat)])]
        var onboarding = OnboardingState()
        onboarding.toggle(.fo)
        onboarding.begin(); onboarding.beginConnections()
        state.onboarding = onboarding
        let restored = try JSONDecoder().decode(AppState.self, from: JSONEncoder().encode(state)).recoveringInFlight()

        XCTAssertEqual(restored.onboarding, onboarding)
        XCTAssertEqual(restored.agents, state.agents)
        XCTAssertEqual(restored.selection, state.selection)
        XCTAssertEqual(restored.draft, state.draft)
        XCTAssertEqual(restored.comparisons.first?.id, state.comparisons.first?.id)
        XCTAssertEqual(restored.comparisons.first?.members.first?.agentID, agent.id)
    }

    func testSkippingAllStepsRequiresConnectingAtLeastOneAgent() {
        var onboarding = OnboardingState()
        for choice: OnboardingChoice in [.chatgpt, .fo, .szn] { onboarding.toggle(choice) }
        onboarding.begin(); onboarding.beginConnections()
        onboarding.skipCurrentStep()
        XCTAssertEqual(onboarding.currentStep, .messages)
        onboarding.skipCurrentStep()

        XCTAssertFalse(onboarding.isFinished)
        XCTAssertEqual(onboarding.stage, .choosing)
        XCTAssertTrue(onboarding.completed.isEmpty)
        XCTAssertEqual(onboarding.skipped, onboarding.selected)
        XCTAssertTrue(onboarding.pendingSteps.isEmpty)
    }

    func testBackAndSelectionChangesDoNotRepeatCompletedOrDuplicateSteps() {
        var onboarding = OnboardingState()
        onboarding.toggle(.chatgpt)
        onboarding.toggle(.fo)
        onboarding.begin(); onboarding.beginConnections()
        onboarding.complete(.chatgpt)
        onboarding.chooseAgain()
        onboarding.toggle(.chatgpt)
        onboarding.toggle(.chatgpt)
        onboarding.toggle(.instinct)
        onboarding.toggle(.claudeCode)
        onboarding.begin(); onboarding.beginConnections()

        XCTAssertEqual(onboarding.completed, [.chatgpt])
        XCTAssertEqual(onboarding.pendingSteps, [.agent(.claudeCode), .messages])
        XCTAssertEqual(onboarding.pendingChoices, [.instinct, .fo, .claudeCode])
    }

    func testCannotBeginAnEmptySelectionOrChangeItDuringConnection() {
        var onboarding = OnboardingState()
        onboarding.begin(); onboarding.beginConnections()
        XCTAssertEqual(onboarding.stage, .choosing)
        XCTAssertFalse(onboarding.isFinished)
        onboarding.toggle(.chatgpt)
        onboarding.begin(); onboarding.beginConnections()
        onboarding.toggle(.fo)
        XCTAssertEqual(onboarding.selected, [.chatgpt])
        onboarding.complete(.chatgpt)
        onboarding.finish()
        XCTAssertTrue(onboarding.isFinished)
    }

    func testFinishRequiresResolvedChoicesAndCompletingClearsSkip() {
        var onboarding = OnboardingState()
        for choice: OnboardingChoice in [.chatgpt, .claude, .fo] { onboarding.toggle(choice) }
        onboarding.begin(); onboarding.beginConnections()
        onboarding.skip(.chatgpt)
        onboarding.complete(.chatgpt)
        onboarding.finish()

        XCTAssertEqual(onboarding.stage, .connecting)
        XCTAssertTrue(onboarding.skipped.isEmpty)
        onboarding.skip(.claude)
        onboarding.skip(.fo)
        XCTAssertEqual(onboarding.stage, .feedback)
        onboarding.finish()

        XCTAssertTrue(onboarding.isFinished)
        XCTAssertEqual(onboarding.completed, [.chatgpt])
        XCTAssertEqual(onboarding.skipped, [.claude, .fo])
        XCTAssertTrue(onboarding.pendingChoices.isEmpty)
    }

    func testCannotFinishWithoutOneSelectedChatReadyAgent() {
        var onboarding = OnboardingState()
        onboarding.toggle(.chatgpt)
        onboarding.begin(); onboarding.beginConnections()
        onboarding.finish()
        XCTAssertFalse(onboarding.isFinished)
    }

    func testRuntimeSetupIsSeparateFromMessagesAndDoesNotUnlockChat() {
        var onboarding = OnboardingState()
        onboarding.toggle(.openclaw)
        onboarding.toggle(.hermes)
        XCTAssertFalse(OnboardingChoice.openclaw.isMessages)
        XCTAssertFalse(OnboardingChoice.hermes.isMessages)
        onboarding.begin(); onboarding.beginConnections()
        XCTAssertEqual(onboarding.pendingSteps, [.runtime(.openclaw), .runtime(.hermes)])
        onboarding.complete(.openclaw)
        onboarding.complete(.hermes)
        XCTAssertFalse(onboarding.hasConnectedAgent)
        XCTAssertEqual(onboarding.stage, .choosing)
        onboarding.toggle(.chatgpt)
        onboarding.begin(); onboarding.beginConnections()
        XCTAssertEqual(onboarding.pendingSteps, [.agent(.chatgpt)])
        onboarding.complete(.chatgpt)
        onboarding.finish()
        XCTAssertTrue(onboarding.isFinished)
    }

    func testRecheckingSavedConnectionsPreservesExplicitSkips() {
        var onboarding = OnboardingState()
        for choice: OnboardingChoice in [.chatgpt, .grokbot, .fo] { onboarding.toggle(choice) }
        onboarding.begin(); onboarding.beginConnections()
        onboarding.complete(.chatgpt)
        onboarding.skip(.grokbot)
        onboarding.chooseAgain()
        onboarding.completed = []
        onboarding.begin(); onboarding.beginConnections()
        XCTAssertEqual(onboarding.skipped, [.grokbot])
        XCTAssertEqual(onboarding.pendingSteps, [.agent(.chatgpt), .messages])
    }

    func testRestartOnFeedbackScreenRechecksConnectionsWithoutLosingSkips() throws {
        var onboarding = OnboardingState()
        for choice: OnboardingChoice in [.chatgpt, .grokbot] { onboarding.toggle(choice) }
        onboarding.begin(); onboarding.beginConnections()
        onboarding.complete(.chatgpt)
        onboarding.skip(.grokbot)
        var restored = try JSONDecoder().decode(OnboardingState.self, from: JSONEncoder().encode(onboarding))
        XCTAssertEqual(restored.stage, .feedback)
        restored.recheckConnections()
        XCTAssertEqual(restored.stage, .connecting)
        XCTAssertEqual(restored.skipped, [.grokbot])
        XCTAssertEqual(restored.pendingSteps, [.agent(.chatgpt)])
        restored.finish()
        XCTAssertFalse(restored.isFinished)
        restored.complete(.chatgpt)
        restored.finish()
        XCTAssertTrue(restored.isFinished)
        restored.recheckConnections()
        XCTAssertTrue(restored.isFinished)
        XCTAssertEqual(restored.completed, [.chatgpt])
    }
}
