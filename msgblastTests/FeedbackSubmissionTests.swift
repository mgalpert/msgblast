import XCTest
import msgblastCore

final class FeedbackSubmissionTests: XCTestCase {
    private let id = UUID(uuidString: "F7088F79-091A-4F25-8B73-FF27E911A901")!

    func testBodyContainsOnlyNoteContactAndOptInPreview() throws {
        var facts = DiagnosticFacts.empty()
        facts.lastError = "secret token /Users/private/chat.db"
        facts.supportFolder = "/Users/private"
        facts.updatesReason = "sk-secret"
        facts.permissions = ["accessibility": "allowed", "screenRecording": "off", "contacts": "restricted",
                             "messagesDatabase": "unknown", "messagesAutomation": "notRequested",
                             "private": "/Users/private"]
        var request = DiagnosticRequest(kind: .bug, note: "  Cannot save\n", contact: " ada@example.com ", facts: facts)
        let excluded = try object(FeedbackSubmission.encodeRequest(request, id: id))
        XCTAssertEqual(Set(excluded.keys), ["id", "kind", "note", "contact"])
        XCTAssertEqual(excluded["id"] as? String, id.uuidString)
        XCTAssertEqual(excluded["kind"] as? String, "bug")
        XCTAssertEqual(excluded["note"] as? String, "Cannot save")
        XCTAssertEqual(excluded["contact"] as? String, "ada@example.com")
        request.includeDiagnostics = true
        let included = try object(FeedbackSubmission.encodeRequest(request, id: id))
        let preview = try XCTUnwrap(included["diagnostics"] as? String)
        XCTAssertEqual(preview, DiagnosticReport.diagnosticsJSON(facts))
        let diagnostics = try object(Data(preview.utf8))
        XCTAssertEqual(diagnostics["permissions"] as? [String: String], [
            "accessibility": "allowed", "screenRecording": "off", "contacts": "restricted",
            "messagesDatabase": "unknown", "messagesAutomation": "notRequested"
        ])
        XCTAssertFalse(preview.contains("secret"))
        XCTAssertFalse(preview.contains("/Users/"))
        XCTAssertNil(included["archive"])
        XCTAssertNil(included["facts"])
    }

    func testBodyUsesExistingValidationAndOmitsBlankContact() throws {
        var request = DiagnosticRequest(kind: .feedback, note: "Hello", contact: " \n", facts: .empty())
        XCTAssertNil(try object(FeedbackSubmission.encodeRequest(request, id: id))["contact"])
        for note in [" \n", String(repeating: "a", count: 8001)] {
            request.note = note
            XCTAssertThrowsError(try FeedbackSubmission.encodeRequest(request, id: id))
        }
        request.note = "Hello"
        request.contact = "invalid address"
        XCTAssertThrowsError(try FeedbackSubmission.encodeRequest(request, id: id))
    }

    func testJoinedEmojiPreflightMatchesServerSizeLimit() throws {
        let note = String(repeating: "👨‍👩‍👧‍👦", count: 1600)
        let request = DiagnosticRequest(kind: .feedback, note: note, facts: .empty())
        XCTAssertEqual(note.count, 1600)
        XCTAssertNoThrow(try DiagnosticReport.make(request))
        XCTAssertThrowsError(try FeedbackSubmission.encodeRequest(request, id: id)) { error in
            XCTAssertEqual(error as? FeedbackSubmissionError, .reportTooLarge)
        }
    }

    func testEndpointIsFixedExceptExplicitLoopbackFixture() throws {
        try FeedbackSubmission.validateEndpoint(FeedbackSubmission.productionEndpoint)
        for raw in ["http://msgblast.app/api/feedback", "https://evil.example/api/feedback", "https://msgblast.app/other", "https://user:pass@msgblast.app/api/feedback", "https://msgblast.app/api/feedback?token=x", "https://msgblast.app/api/feedback#x", "https://msgblast.app:8443/api/feedback", "http://localhost:8123/api/feedback"] {
            XCTAssertThrowsError(try FeedbackSubmission.validateEndpoint(URL(string: raw)!))
        }
        for host in ["localhost", "127.0.0.1", "[::1]"] {
            try FeedbackSubmission.validateEndpoint(URL(string: "http://\(host):8123/api/feedback")!, isLocalFixture: true)
        }
        XCTAssertThrowsError(try FeedbackSubmission.validateEndpoint(URL(string: "http://evil.example/api/feedback")!, isLocalFixture: true))
    }

    func testReceiptRequiresMatchingIDAndSuccessfulStatus() throws {
        let receipt = Data("{\"id\":\"\(id.uuidString)\"}".utf8)
        XCTAssertEqual(try FeedbackSubmission.receipt(from: receipt, statusCode: 201, id: id).id, id)
        XCTAssertEqual(try FeedbackSubmission.receipt(from: receipt, statusCode: 200, id: id).id, id)
        for data in [Data("{}".utf8), Data("no json".utf8), Data("{\"id\":\"\(UUID().uuidString)\"}".utf8), Data(repeating: 65, count: 8193)] {
            XCTAssertThrowsError(try FeedbackSubmission.receipt(from: data, statusCode: 201, id: id))
        }
        for code in [202, 301, 307, 400, 413, 429, 500, 503] {
            XCTAssertThrowsError(try FeedbackSubmission.receipt(from: receipt, statusCode: code, id: id))
        }
        XCTAssertThrowsError(try FeedbackSubmission.receipt(from: receipt, statusCode: 429, id: id)) { error in
            XCTAssertEqual(error as? FeedbackSubmissionError, .rateLimited)
        }
    }

    func testSessionDoesNotRetainCookiesOrCache() {
        let config = FeedbackSubmission.sessionConfiguration()
        XCTAssertNil(config.httpCookieStorage)
        XCTAssertFalse(config.httpShouldSetCookies)
        XCTAssertNil(config.urlCache)
        XCTAssertEqual(config.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(config.timeoutIntervalForRequest, 20)
    }

    func testSendUsesInjectedTransportAndAcceptsOnlyConfirmedReceipt() async throws {
        let config = FeedbackSubmission.sessionConfiguration()
        config.protocolClasses = [FeedbackProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let request = DiagnosticRequest(kind: .feedback, note: "Local fixture", facts: .empty())
        let receipt = try await FeedbackSubmission.send(request, id: id,
            endpoint: URL(string: "http://127.0.0.1:8811/api/feedback")!, isLocalFixture: true, session: session)
        XCTAssertEqual(receipt.id, id)
        for (port, expected) in [(8812, FeedbackSubmissionError.rateLimited), (8813, .redirectRejected), (8814, .invalidReceipt), (8815, .connectionFailed)] {
            do {
                _ = try await FeedbackSubmission.send(request, id: id,
                    endpoint: URL(string: "http://127.0.0.1:\(port)/api/feedback")!, isLocalFixture: true, session: session)
                XCTFail("Expected transport failure on port \(port)")
            } catch {
                XCTAssertEqual(error as? FeedbackSubmissionError, expected)
            }
        }
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}


private final class FeedbackProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        if url.port == 8815 {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let status = url.port == 8812 ? 429 : url.port == 8813 ? 307 : 201
        let body = url.port == 8814 ? "{}" : "{\"id\":\"F7088F79-091A-4F25-8B73-FF27E911A901\"}"
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
