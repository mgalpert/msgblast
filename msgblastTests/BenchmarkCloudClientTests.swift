import XCTest
@testable import msgblastCore

@MainActor final class BenchmarkCloudClientTests: XCTestCase {
    private func setup(_ root: URL) async throws -> (BenchmarkCloudClient, CloudHTTP, [PerformanceEvent]) {
        let config = try BenchmarkAccountConfiguration(serviceURL: URL(string: "http://127.0.0.1:8787")!, issuer: URL(string: "https://fixture.invalid/")!, clientID: "fixture", audience: "fixture", callbackURL: URL(string: "com.msgblast.test:/benchmark")!, bundleIdentifier: "com.msgblast.test", profile: UUID().uuidString, demoFixture: true)
        let http = CloudHTTP(), tokens = CloudTokens()
        tokens.token = .init(accessToken: "synthetic-token", refreshToken: nil, expiresAt: .distantFuture, accountID: "owner-a")
        let account = BenchmarkAccountSession(configuration: config, browser: CloudBrowser(), transport: http, tokenStore: tokens)
        await account.restore(); XCTAssertEqual(account.account?.accountID, "owner-a")
        let recorder = try PerformanceRecorder(directory: root, fixture: true); recorder.enabled = true
        _ = try recorder.beginTurn(comparisonID: "comparison", agent: .init(id: "agent", name: "Synthetic", connection: .cli), text: "Synthetic prompt", scope: .shared)
        return (BenchmarkCloudClient(account: account, store: try BenchmarkSyncStore(directory: root)), http, recorder.events)
    }
    func testIndependentPublicationUsesOnlyApprovedProjection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let (client, http, events) = try await setup(root)
        var projection = try ComparisonPublicationBuilder.build(events: events, comparisonID: "comparison")
        projection.turns[0].prompt = "Manually redacted\n  preview"
        _ = try await client.publish(projection, comparisonID: "comparison", owner: "owner-a")
        XCTAssertTrue(client.store.paused); XCTAssertTrue(client.store.lineages.isEmpty)
        XCTAssertEqual(http.requests.map { $0.url!.path }, ["/api/v1/account", "/api/v1/publications"])
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(http.requests.last?.httpBody)) as! [String: Any]
        XCTAssertEqual(body["localID"] as? String, "comparison", "Publication must retain private comparison association without uploading raw events")
        XCTAssertEqual(body["previewHash"] as? String, try projection.previewHash())
        let sent = try JSONDecoder().decode(ComparisonPublication.self, from: JSONSerialization.data(withJSONObject: body["projection"]!))
        XCTAssertEqual(sent, projection)
    }
    func testPublicationAssociatesOnlyVerifiedOwnersExistingLineageAndStaleApprovalCannotTransmit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let (client, http, events) = try await setup(root)
        var lineage = try client.store.prepare(events: events, comparisonID: "comparison", owner: "owner-a", context: "unknown")
        lineage.sessionID = "cloud-session"; lineage.snapshotID = "head-one"; try client.store.update(lineage)
        let approval = try XCTUnwrap(BenchmarkContributionApproval(lineage: lineage, owner: "owner-a"))
        let projection = try ComparisonPublicationBuilder.build(events: events, comparisonID: "comparison")
        _ = try await client.publish(projection, comparisonID: "comparison", owner: "owner-a")
        let body = try JSONSerialization.jsonObject(with: http.requests.last!.httpBody!) as! [String: Any]
        XCTAssertEqual(body["sessionID"] as? String, "cloud-session"); XCTAssertEqual(body["localID"] as? String, "comparison")
        XCTAssertEqual(body["previewHash"] as? String, try projection.previewHash())
        lineage.snapshotID = "head-two"; try client.store.update(lineage)
        let count = http.requests.count
        do { _ = try await client.contributeSelected(approval); XCTFail("Consent for head-one cannot authorize head-two") } catch { XCTAssertEqual(error as? BenchmarkSyncError, .staleOperation) }
        XCTAssertEqual(http.requests.count, count)
        let renewedApproval = try XCTUnwrap(BenchmarkContributionApproval(lineage: lineage, owner: "owner-a"))
        http.holdHistory = true
        let contributing = Task { try await client.contributeSelected(renewedApproval) }
        while http.pending == nil { await Task.yield() }
        lineage.snapshotID = "head-three"; try client.store.update(lineage); http.completeChunk()
        do { _ = try await contributing.value; XCTFail("Head changed while reading history") } catch { XCTAssertEqual(error as? BenchmarkSyncError, .staleOperation) }
        XCTAssertFalse(http.requests.contains { $0.url!.path.hasSuffix("/contribution") })
        lineage.snapshotID = nil; try client.store.update(lineage)
        XCTAssertNil(BenchmarkContributionApproval(lineage: lineage, owner: "owner-a"))
    }
    func testInterruptedChunkRetryPreservesBytesThenContributionDoesNotEnableSync() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let (client, http, events) = try await setup(root)
        let selected = try client.store.prepare(events: events, comparisonID: "comparison", owner: "owner-a", context: "unknown", purpose: "contribution")
        http.failChunk = true
        do { _ = try await client.upload(comparisonID: "comparison", owner: "owner-a", contributionSelection: true); XCTFail("Offline upload must remain pending") } catch {}
        XCTAssertTrue(client.store.paused)
        XCTAssertFalse(client.store.lineages[0].chunks[0].acknowledged)
        XCTAssertEqual(client.store.lineages[0].chunks[0].bytes, selected.chunks[0].bytes)
        let restored = BenchmarkCloudClient(account: client.account, store: try BenchmarkSyncStore(directory: root)); http.failChunk = false
        let snapshot = try await restored.upload(comparisonID: "comparison", owner: "owner-a", contributionSelection: true)
        XCTAssertTrue(restored.store.paused)
        XCTAssertEqual(snapshot.sequenceEnd, events.count)
        let attempts = http.requests.filter { $0.url!.path.hasSuffix("/chunks") }
        XCTAssertEqual(attempts.count, 4)
        XCTAssertTrue(attempts.allSatisfy { $0.httpBody == selected.chunks[0].bytes })
        XCTAssertFalse(http.requests.contains { $0.url!.path.hasSuffix("/contribution") })
        _ = try await restored.contribute(sessionID: snapshot.sessionID, snapshotID: snapshot.snapshotID, contributionRevision: 1, owner: "owner-a")
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(http.requests.last?.httpBody)) as! [String: Any]
        XCTAssertEqual(body["snapshotID"] as? String, snapshot.snapshotID)
        XCTAssertTrue(restored.store.paused)
    }
    func testPauseRejectsLateReceiptAndDifferentOwnerNeverTransmits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let (client, http, events) = try await setup(root)
        _ = try client.store.prepare(events: events, comparisonID: "comparison", owner: "owner-a", context: "unknown")
        try client.resume(); http.holdChunk = true
        let task = Task { try await client.upload(comparisonID: "comparison", owner: "owner-a") }
        while http.pending == nil { await Task.yield() }
        try client.pause(); http.completeChunk()
        do { _ = try await task.value; XCTFail("Paused operation must be rejected") } catch {}
        XCTAssertFalse(client.store.lineages[0].chunks[0].acknowledged)
        let count = http.requests.count
        do { _ = try await client.upload(comparisonID: "comparison", owner: "owner-b"); XCTFail("Wrong owner") } catch {}
        XCTAssertEqual(http.requests.count, count)
    }
    func testPermanentQuotaStopsExactUploadRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let (client, http, events) = try await setup(root)
        _ = try client.store.prepare(events: events, comparisonID: "comparison", owner: "owner-a", context: "unknown")
        try client.resume(); http.quotaChunk = true
        do { _ = try await client.upload(comparisonID: "comparison", owner: "owner-a"); XCTFail("Quota must reject upload") }
        catch { XCTAssertEqual(error as? BenchmarkAccountError, .quota) }
        XCTAssertEqual(http.requests.filter { $0.url!.path.hasSuffix("/chunks") }.count, 1)
        XCTAssertFalse(client.store.lineages[0].chunks[0].acknowledged)
    }

}
@MainActor private final class CloudBrowser: BenchmarkOAuthBrowser {
    func authenticate(url: URL, callbackScheme: String) async throws -> URL { throw BenchmarkAccountError.cancelled }
    func cancel() {}
}
@MainActor private final class CloudTokens: BenchmarkTokenStore {
    var token: BenchmarkAccountTokens?
    func read(scope: String) throws -> BenchmarkAccountTokens? { token }
    func save(_ tokens: BenchmarkAccountTokens, scope: String) throws { token = tokens }
    func delete(scope: String) throws { token = nil }
}
@MainActor private final class CloudHTTP: BenchmarkHTTPTransport {
    var requests: [URLRequest] = []
    var failChunk = false, holdChunk = false, quotaChunk = false, holdHistory = false
    var pending: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    var pendingRequest: URLRequest?
    var headHash = "", sequenceEnd = 0
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if request.url!.path.hasSuffix("/chunks") {
            if quotaChunk { return (Data("{\"error\":\"account_quota\"}".utf8), HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!) }
            if failChunk { throw URLError(.notConnectedToInternet) }
            if holdChunk { pendingRequest = request; return try await withCheckedThrowingContinuation { pending = $0 } }
        }
        if request.url!.path.hasSuffix("/contributions"), holdHistory { pendingRequest = request; return try await withCheckedThrowingContinuation { pending = $0 } }
        return try response(request)
    }
    private func response(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let path = request.url!.path
        var value: [String: Any] = ["status": "accepted"]
        if path.hasSuffix("/account") { value = ["accountID": "owner-a", "identity": "fixture bearer"] }
        else if path.hasSuffix("/contributions") { value = ["history": [], "acceptedDistinctSessions": 0] }
        else if path.hasSuffix("/sessions") { value = ["id": "cloud-session"] }
        else if path.hasSuffix("/chunks") {
            let chunk = try JSONDecoder().decode(PerformanceUploadChunk.self, from: request.httpBody!)
            headHash = PerformanceCanonical.hash(request.httpBody!); sequenceEnd = chunk.sequenceEnd
            value = ["id": chunk.id, "hash": headHash]
        } else if path.hasSuffix("/finalize") { value = ["sessionID": "cloud-session", "revision": 1, "snapshotID": "snapshot", "sequenceEnd": sequenceEnd, "hash": headHash, "status": "pending-validation"] }
        else if path.hasSuffix("/publications") { value = ["id": "publication", "path": "/s/synthetic-capability"] }
        return (try JSONSerialization.data(withJSONObject: value), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    func completeChunk() { let request = pendingRequest!; let continuation = pending!; pending = nil; pendingRequest = nil; continuation.resume(with: Result { try response(request) }) }
    func cancelAll() {}
}
