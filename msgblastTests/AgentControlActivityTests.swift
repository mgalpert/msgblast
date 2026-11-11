import XCTest
@testable import msgblastCore
import msgblastRemoteProtocol

@MainActor final class AgentControlActivityTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() async throws {
        suite = "AgentControlActivityTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() async throws { defaults.removePersistentDomain(forName: suite) }

    private func start(_ agents: [String] = ["chatgpt", "claude"]) -> RemoteCommand {
        RemoteCommand(action: .createConversation(text: "Secret plans", agentIDs: agents, attachmentIDs: []))
    }

    func testASendIsListedWhileItRunsAndThenWithItsResultButNeverItsText() async {
        let activity = AgentControlActivity(defaults: defaults)
        let command = start()
        var seen: AgentControlActivityEntry?
        let result = await activity.run(command, client: "Codex", known: false) { command in
            seen = activity.log.running
            return .init(clientCommandID: command.clientCommandID, outcome: .applied)
        }
        XCTAssertEqual(result.outcome, .applied)
        XCTAssertEqual(seen?.summary, "Codex · Started a blast · 2 agents")
        XCTAssertNil(activity.log.running)
        XCTAssertEqual(activity.log.entries.map(\.result), ["Done"])
        XCTAssertFalse(String(describing: activity.log).contains("Secret plans"))
    }

    func testStoppedSendsAreRefusedListedAndStayStoppedAfterRestart() async {
        let activity = AgentControlActivity(defaults: defaults)
        activity.stopped = true
        var sent = 0
        let result = await activity.run(start(), client: "Codex", known: false) { command in
            sent += 1
            return .init(clientCommandID: command.clientCommandID, outcome: .applied)
        }
        XCTAssertEqual(sent, 0)
        XCTAssertEqual(result.outcome, .rejected)
        XCTAssertEqual(result.code, .agentSendsStopped)
        XCTAssertEqual(activity.log.entries.first?.result?.hasPrefix("Refused: Agent sends are stopped"), true)
        XCTAssertTrue(AgentControlActivity(defaults: defaults).stopped)
    }

    func testRepeatsOfAKnownRequestAddNoEntryAndAreAnsweredEvenWhenStopped() async {
        let activity = AgentControlActivity(defaults: defaults)
        activity.stopped = true
        let result = await activity.run(start(), client: "Codex", known: true) { command in
            var stored = RemoteCommandResult(clientCommandID: command.clientCommandID, outcome: .applied)
            stored.replayed = true
            return stored
        }
        XCTAssertTrue(result.replayed)
        XCTAssertTrue(activity.log.entries.isEmpty)
    }

    func testEachSendKindIsDescribedAndOtherCommandsAreNotListed() {
        var log = AgentControlActivityLog()
        let conversation = UUID()
        log.begin(RemoteCommand(action: .sendShared(conversationID: conversation, text: "x", agentIDs: [], attachmentIDs: [])), client: "A")
        log.begin(RemoteCommand(action: .sendShared(conversationID: conversation, text: "x", agentIDs: ["chatgpt"], attachmentIDs: [])), client: "A")
        log.begin(RemoteCommand(action: .sendPrivate(conversationID: conversation, agentID: "chatgpt", text: "x", attachmentIDs: [])), client: "A")
        log.begin(RemoteCommand(action: .endConversation(conversationID: conversation)), client: "A")
        log.begin(RemoteCommand(action: .setKeepAwake(enabled: true)), client: "A")
        XCTAssertEqual(log.entries.map(\.summary), ["A · Ended a comparison", "A · Messaged one agent · 1 agent",
                                                   "A · Followed up · 1 agent", "A · Followed up"])
    }

    func testResultsAreWordedAndTheListKeepsTheNewest50() {
        var log = AgentControlActivityLog()
        let commands = (0..<52).map { _ in start(["chatgpt"]) }
        for command in commands { log.begin(command, client: "A") }
        XCTAssertEqual(log.entries.count, AgentControlActivityLog.limit)
        XCTAssertEqual(log.entries.first?.id, commands.last?.clientCommandID)
        log.finish(.rejected(commands[51].clientCommandID, .macBusy, "Your Mac is busy"))
        log.finish(.rejected(commands[50].clientCommandID, .unknownCommand, "Lost"))
        log.finish(.rejected(commands[0].clientCommandID, .macBusy, "Dropped from the list"))
        XCTAssertEqual(log.entries.prefix(2).map(\.result), ["Refused: Your Mac is busy", "Not confirmed"])
        XCTAssertEqual(log.running?.id, commands[49].clientCommandID)
    }
}
