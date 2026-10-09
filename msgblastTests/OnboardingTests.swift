import XCTest
@testable import msgblastCore

final class OnboardingTests: XCTestCase {
    func testEmptyMessagesConfirmationClearsOldRowsWhileAnotherProviderPermitsFinish() {
        var onboarding = OnboardingState()
        for choice: OnboardingChoice in [.chatgpt, .fo, .szn] { onboarding.toggle(choice) }
        onboarding.begin()
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
        onboarding.begin()
        onboarding.confirmMessages(connected: [.instinct, .fo], skipped: [.szn])
        XCTAssertEqual(onboarding.completed, [.instinct, .fo])
        XCTAssertEqual(onboarding.skipped, [.szn])
        XCTAssertEqual(onboarding.stage, .feedback)
        XCTAssertFalse(onboarding.isFinished)
    }

    func testMessagesConfirmationKeepsMissingConversationsPending() {
        var onboarding = OnboardingState()
        for choice: OnboardingChoice in [.fo, .szn, .otherMessages] { onboarding.toggle(choice) }
        onboarding.begin()
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
        onboarding.begin()
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
        onboarding.begin()
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
        onboarding.begin()

        XCTAssertEqual(onboarding.pendingSteps, [.agent(.chatgpt), .agent(.grokbot), .agent(.claudeCode), .messages])
        XCTAssertEqual(onboarding.currentStep, .agent(.chatgpt))
        XCTAssertEqual(onboarding.pendingChoices, [.chatgpt, .grokbot, .instinct, .fo, .szn, .claudeCode, .otherMessages])
        XCTAssertEqual(onboarding.stage, .connecting)
    }

    func testMessagesCompletionAndIndividualSkipKeepTheGroupUntilResolved() {
        var onboarding = OnboardingState()
        for choice: OnboardingChoice in [.instinct, .fo, .szn] { onboarding.toggle(choice) }
        onboarding.begin()
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
        onboarding.begin()
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
        resumed.begin()
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
        onboarding.begin()
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
        onboarding.begin()
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
        onboarding.begin()
        onboarding.complete(.chatgpt)
        onboarding.chooseAgain()
        onboarding.toggle(.chatgpt)
        onboarding.toggle(.chatgpt)
        onboarding.toggle(.instinct)
        onboarding.toggle(.claudeCode)
        onboarding.begin()

        XCTAssertEqual(onboarding.completed, [.chatgpt])
        XCTAssertEqual(onboarding.pendingSteps, [.agent(.claudeCode), .messages])
        XCTAssertEqual(onboarding.pendingChoices, [.instinct, .fo, .claudeCode])
    }

    func testCannotBeginAnEmptySelectionOrChangeItDuringConnection() {
        var onboarding = OnboardingState()
        onboarding.begin()
        XCTAssertEqual(onboarding.stage, .choosing)
        XCTAssertFalse(onboarding.isFinished)
        onboarding.toggle(.chatgpt)
        onboarding.begin()
        onboarding.toggle(.fo)
        XCTAssertEqual(onboarding.selected, [.chatgpt])
        onboarding.complete(.chatgpt)
        onboarding.finish()
        XCTAssertTrue(onboarding.isFinished)
    }

    func testFinishRequiresResolvedChoicesAndCompletingClearsSkip() {
        var onboarding = OnboardingState()
        for choice: OnboardingChoice in [.chatgpt, .claude, .fo] { onboarding.toggle(choice) }
        onboarding.begin()
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
        onboarding.begin()
        onboarding.finish()
        XCTAssertFalse(onboarding.isFinished)
    }

    func testRuntimeSetupIsSeparateFromMessagesAndDoesNotUnlockChat() {
        var onboarding = OnboardingState()
        onboarding.toggle(.openclaw)
        onboarding.toggle(.hermes)
        XCTAssertFalse(OnboardingChoice.openclaw.isMessages)
        XCTAssertFalse(OnboardingChoice.hermes.isMessages)
        onboarding.begin()
        XCTAssertEqual(onboarding.pendingSteps, [.runtime(.openclaw), .runtime(.hermes)])
        onboarding.complete(.openclaw)
        onboarding.complete(.hermes)
        XCTAssertFalse(onboarding.hasConnectedAgent)
        XCTAssertEqual(onboarding.stage, .choosing)
        onboarding.toggle(.chatgpt)
        onboarding.begin()
        XCTAssertEqual(onboarding.pendingSteps, [.agent(.chatgpt)])
        onboarding.complete(.chatgpt)
        onboarding.finish()
        XCTAssertTrue(onboarding.isFinished)
    }

    func testRecheckingSavedConnectionsPreservesExplicitSkips() {
        var onboarding = OnboardingState()
        for choice: OnboardingChoice in [.chatgpt, .grokbot, .fo] { onboarding.toggle(choice) }
        onboarding.begin()
        onboarding.complete(.chatgpt)
        onboarding.skip(.grokbot)
        onboarding.chooseAgain()
        onboarding.completed = []
        onboarding.begin()
        XCTAssertEqual(onboarding.skipped, [.grokbot])
        XCTAssertEqual(onboarding.pendingSteps, [.agent(.chatgpt), .messages])
    }

    func testRestartOnFeedbackScreenRechecksConnectionsWithoutLosingSkips() throws {
        var onboarding = OnboardingState()
        for choice: OnboardingChoice in [.chatgpt, .grokbot] { onboarding.toggle(choice) }
        onboarding.begin()
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
