import XCTest
@testable import msgblastCore

@MainActor final class AgentControlSessionsTests: XCTestCase {
    private final class Session {}
    private final class Cancelled { var sessions: [ObjectIdentifier] = [] }

    private func make(_ cancelled: Cancelled) -> AgentControlSessions<Session> {
        AgentControlSessions { cancelled.sessions.append(ObjectIdentifier($0)) }
    }

    func testOffRefusesNewSessions() {
        let cancelled = Cancelled()
        let sessions = make(cancelled)
        let session = Session()
        XCTAssertFalse(sessions.add(session))
        XCTAssertEqual(cancelled.sessions, [ObjectIdentifier(session)])
        XCTAssertEqual(sessions.count, 0)
    }

    func testSwitchingOffCancelsSessionsAlreadyOpen() {
        let cancelled = Cancelled()
        let sessions = make(cancelled)
        sessions.open()
        let first = Session(), second = Session()
        XCTAssertTrue(sessions.add(first))
        XCTAssertTrue(sessions.add(second))
        XCTAssertTrue(sessions.begin(first))
        XCTAssertTrue(cancelled.sessions.isEmpty)

        sessions.close()
        XCTAssertFalse(sessions.isOpen)
        XCTAssertEqual(sessions.count, 0)
        XCTAssertEqual(Set(cancelled.sessions), [ObjectIdentifier(first), ObjectIdentifier(second)])
        // A request that was running when Outside agents went off gets no reply, and no new one starts.
        XCTAssertFalse(sessions.contains(first))
        XCTAssertFalse(sessions.begin(second))
        let late = Session()
        XCTAssertFalse(sessions.add(late))
        XCTAssertTrue(cancelled.sessions.contains(ObjectIdentifier(late)))
    }

    func testSwitchingBackOnDoesNotReviveOldSessions() {
        let sessions = make(Cancelled())
        sessions.open()
        let old = Session()
        sessions.add(old)
        sessions.close()
        sessions.open()
        XCTAssertFalse(sessions.contains(old))
        XCTAssertFalse(sessions.begin(old))
        let fresh = Session()
        XCTAssertTrue(sessions.add(fresh))
        XCTAssertTrue(sessions.begin(fresh))
    }

    func testSessionEndsAfterItsLastReply() {
        let cancelled = Cancelled()
        let sessions = make(cancelled)
        sessions.open()
        let session = Session()
        sessions.add(session)
        XCTAssertTrue(sessions.begin(session))
        XCTAssertTrue(sessions.begin(session))
        sessions.end(session)
        XCTAssertTrue(sessions.contains(session))
        sessions.finish(session)
        XCTAssertTrue(cancelled.sessions.isEmpty)
        sessions.finish(session)
        XCTAssertEqual(cancelled.sessions, [ObjectIdentifier(session)])
        XCTAssertEqual(sessions.count, 0)
    }

    func testIdleSessionEndsWhenTheAgentStopsSending() {
        let cancelled = Cancelled()
        let sessions = make(cancelled)
        sessions.open()
        let session = Session()
        sessions.add(session)
        sessions.end(session)
        XCTAssertEqual(cancelled.sessions, [ObjectIdentifier(session)])
        XCTAssertFalse(sessions.contains(session))
    }

    func testDropCancelsAtOnce() {
        let cancelled = Cancelled()
        let sessions = make(cancelled)
        sessions.open()
        let session = Session()
        sessions.add(session)
        sessions.begin(session)
        sessions.drop(session)
        XCTAssertEqual(cancelled.sessions, [ObjectIdentifier(session)])
        XCTAssertEqual(sessions.count, 0)
        sessions.finish(session)
        XCTAssertEqual(cancelled.sessions.count, 1)
    }
}
