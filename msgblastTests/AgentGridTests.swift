import XCTest
@testable import msgblastCore

final class AgentGridTests: XCTestCase {
    func testSelectedPokeIsVisibleEvenWithoutAConversationAndSurvivesRestart() throws {
        let poke = UUID()
        var setup = OnboardingState()
        setup.selected = [.fo, .poke]
        setup.completed = [.fo]
        setup.skipped = [.poke]
        setup.messageAgentIDs = ["poke": poke]
        setup.stage = .finished
        let restored = try JSONDecoder().decode(OnboardingState.self, from: JSONEncoder().encode(setup))
        XCTAssertEqual(AgentGridLayout(onboarding: restored, messageGridIDs: [:]).visibleIDs, [.messages(poke)])
        var deselected = restored
        deselected.selected.remove(.poke)
        XCTAssertTrue(AgentGridLayout(onboarding: deselected, messageGridIDs: [:]).visibleIDs.isEmpty)
    }

    func testAllDiscoveredMessagesAgentsSurviveOnboardingAndRestart() throws {
        let first = UUID(), second = UUID(), third = UUID()
        var setup = OnboardingState()
        setup.selected = [.otherMessages]
        setup.completed = [.otherMessages]
        setup.messageAgentIDs = ["otherMessages": first]
        setup.discoveredMessageAgentIDs = [first, second, third]
        setup.messagesDiscoveryReviewed = true
        setup.excludedDiscoveredMessageAgentIDs = [UUID()]
        let restored = try JSONDecoder().decode(OnboardingState.self, from: JSONEncoder().encode(setup))
        let grid = AgentGridLayout(onboarding: restored, messageGridIDs: [:])
        XCTAssertEqual(grid.visibleIDs, [.messages(first), .messages(second), .messages(third)])
        XCTAssertEqual(restored.messagesDiscoveryReviewed, true)
        XCTAssertEqual(restored.excludedDiscoveredMessageAgentIDs, setup.excludedDiscoveredMessageAgentIDs)
        XCTAssertFalse(grid.visibleIDs.contains(.messages(setup.excludedDiscoveredMessageAgentIDs![0])))
    }

    func testCompletedOnboardingShowsSelectedChoicesIncludingPendingSetup() throws {
        let foID = UUID(), otherID = UUID()
        var setup = OnboardingState()
        setup.selected = [.hark, .chatgpt, .fo, .otherMessages, .openclaw, .claude]
        setup.completed = [.hark, .chatgpt, .fo, .otherMessages, .openclaw, .grok]
        setup.skipped = [.claude]
        setup.messageAgentIDs = ["fo": foID, "otherMessages": otherID]
        setup.stage = .finished
        let grid = AgentGridLayout(onboarding: setup, messageGridIDs: [foID: .featuredMessages(.fo)])
        XCTAssertEqual(grid.visibleIDs, [.web(.chatgpt), .web(.claude), .featuredMessages(.fo), .runtime(.openclaw), .web(.hark), .messages(otherID)])
        let catalog = grid.visibleIDs + [.web(.claude), .web(.grok), .featuredMessages(.szn)]
        XCTAssertEqual(grid.available(in: catalog), [.web(.grok), .featuredMessages(.szn)])
        var state = AppState()
        state.onboarding = setup
        state.agentGrid = grid
        state.draft = "Keep my draft"
        let restored = try JSONDecoder().decode(AppState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored.agentGrid?.visibleIDs, grid.visibleIDs)
        XCTAssertEqual(restored.draft, "Keep my draft")
    }

    func testOldStateUsesFeaturedDefaultsWithoutChangingRecipients() throws {
        var original = AppState()
        let contact = Agent(name: "My agent", handles: ["agent@example.com"])
        original.agents = [contact]
        original.selection = [contact.id]
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        json.removeValue(forKey: "agentGrid")
        let restored = try JSONDecoder().decode(AppState.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(restored.agentGrid)
        XCTAssertEqual(AgentGridLayout.featured, [
            .web(.muse), .web(.chatgpt), .web(.claude), .web(.grok), .web(.codexCLI), .web(.dots), .web(.os3),
            .featuredMessages(.instinct), .featuredMessages(.fo), .featuredMessages(.szn)
        ])
        XCTAssertEqual(restored.selection, [contact.id])
    }

    func testHideAddAndReorderSurviveRestartWithoutDeletingAccountsOrDrafts() throws {
        var state = AppState()
        let contact = Agent(name: "My agent", handles: ["agent@example.com"])
        state.agents = [contact]
        state.selection = [contact.id]
        state.draft = "Keep my unsent message"
        var grid = AgentGridLayout(visibleIDs: AgentGridLayout.featured + [.messages(contact.id)])
        grid.hide(.web(.muse))
        grid.add(.web(.grokbot))
        grid.add(.runtime(.openclaw))
        grid.move(.web(.chatgpt), to: .featuredMessages(.fo))
        grid.add(.web(.grokbot))
        state.agentGrid = grid

        let restored = try JSONDecoder().decode(AppState.self, from: JSONEncoder().encode(state))
        let savedGrid = try XCTUnwrap(restored.agentGrid)
        XCTAssertFalse(savedGrid.visibleIDs.contains(.web(.muse)))
        XCTAssertEqual(savedGrid.visibleIDs.prefix(2), [.runtime(.openclaw), .web(.grokbot)])
        XCTAssertEqual(savedGrid.visibleIDs.filter { $0 == .web(.grokbot) }.count, 1)
        XCTAssertEqual(savedGrid.visibleIDs[9], .web(.chatgpt))
        XCTAssertEqual(restored.agents, [contact])
        XCTAssertEqual(restored.selection, [contact.id])
        XCTAssertEqual(restored.draft, "Keep my unsent message")
    }

    func testEmptyGridStaysEmptyAndHiddenAgentsRemainAvailable() throws {
        var grid = AgentGridLayout(visibleIDs: [.web(.muse)])
        grid.hide(.web(.muse))
        let restored = try JSONDecoder().decode(AgentGridLayout.self, from: JSONEncoder().encode(grid))
        let catalog: [AgentGridID] = [.web(.muse), .web(.claudeCode), .web(.grokbot), .runtime(.hermes)]
        XCTAssertEqual(restored.shown(in: catalog), [])
        XCTAssertEqual(restored.available(in: catalog), catalog)
        grid.add(.web(.muse))
        XCTAssertEqual(grid.shown(in: catalog), [.web(.muse)])
        XCTAssertEqual(grid.available(in: catalog), Array(catalog.dropFirst()))
    }

    func testUnavailableContactDoesNotEraseItsSavedPosition() {
        let contactID = AgentGridID.messages(UUID())
        let grid = AgentGridLayout(visibleIDs: [.web(.claude), contactID, .web(.muse)])
        XCTAssertEqual(grid.shown(in: [.web(.muse), .web(.claude)]), [.web(.claude), .web(.muse)])
        XCTAssertEqual(grid.shown(in: [.web(.muse), contactID, .web(.claude)]), [.web(.claude), contactID, .web(.muse)])
    }

    func testMessagesAccessFiltersGridWithoutLosingSavedAgentsOrOrder() {
        let tiny = AgentGridID.messages(UUID())
        let fo = AgentGridID.featuredMessages(.fo)
        let catalog: [AgentGridID] = [.web(.geminiApp), tiny, fo, .web(.wabi)]
        let grid = AgentGridLayout(visibleIDs: catalog)
        XCTAssertEqual(grid.shown(in: catalog, availableMessages: []), [.web(.geminiApp), .web(.wabi)])
        XCTAssertEqual(grid.shown(in: catalog, availableMessages: [fo]), [.web(.geminiApp), fo, .web(.wabi)])
        XCTAssertEqual(grid.shown(in: catalog, availableMessages: [tiny, fo]), catalog)
        XCTAssertEqual(grid.visibleIDs, catalog, "Access changes must preserve saved positions")
    }

    func testNewAgentTakesFirstPositionAndShiftsTheExistingOrder() {
        var grid = AgentGridLayout(visibleIDs: AgentGridLayout.featured)
        grid.add(.web(.grokbot))
        XCTAssertEqual(grid.visibleIDs, [.web(.grokbot)] + AgentGridLayout.featured)
        grid.add(.runtime(.hermes))
        XCTAssertEqual(grid.visibleIDs, [.runtime(.hermes), .web(.grokbot)] + AgentGridLayout.featured)
    }
}
