import AppKit
import Foundation
import msgblastCore

@main enum BenchmarkControllerReview {
    @MainActor static func main() async throws {
        let _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("benchmark-controller-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func report(_ value: String) { print(value); fflush(nil) }
        let config = try BenchmarkAccountConfiguration(serviceURL: URL(string: "http://127.0.0.1:8787")!, issuer: URL(string: "https://fixture.invalid/")!, clientID: "fixture", audience: "fixture", callbackURL: URL(string: "com.msgblast.test:/benchmark")!, bundleIdentifier: "com.msgblast.test", profile: UUID().uuidString, demoFixture: true)
        let damagedRoot = root.appendingPathComponent("damaged-startup")
        let damagedPerformance = PerformanceController(directory: damagedRoot, fixture: true)
        damagedPerformance.recorder!.enabled = true
        damagedPerformance.capture { _ = try $0.beginTurn(comparisonID: "damaged-startup", agent: .init(id: "fixture", name: "Fixture", connection: .cli), text: "Synthetic private source to preserve", scope: .private) }
        let journal = damagedRoot.appendingPathComponent("Benchmarks/uploads.json")
        try FileManager.default.createDirectory(at: journal.deletingLastPathComponent(), withIntermediateDirectories: true)
        let damagedBytes = Data(#"{"selectedPrivateBytes":"Synthetic private outbox""#.utf8)
        try damagedBytes.write(to: journal)
        let source = damagedRoot.appendingPathComponent("Performance/events.jsonl")
        let sourceBytes = try Data(contentsOf: source), sourceEvents = damagedPerformance.events
        let damagedController = BenchmarkController(directory: damagedRoot, demo: true)
        guard damagedController.client == nil, damagedController.error != nil else { throw ReviewFailure.failed("Damaged startup fixture did not reject outbox") }
        damagedPerformance.beforeDeleteRecords = { try damagedController.clearLocalUploads() }
        damagedPerformance.deleteAll()
        let sourceAfterDelete = try? Data(contentsOf: source)
        let journalAfterDelete = try Data(contentsOf: journal)
        guard damagedPerformance.error != nil, damagedPerformance.events == sourceEvents, sourceAfterDelete == sourceBytes, journalAfterDelete == damagedBytes else { throw ReviewFailure.failed("Damaged startup outbox allowed local source deletion or changed original bytes") }
        report("PASS: startup with damaged upload journal refuses source deletion and preserves both original files")
        damagedController.shutdown()
        let http = ReviewHTTP(), tokens = ReviewTokens()
        tokens.token = .init(accessToken: "A", refreshToken: "refresh-A", expiresAt: http.now.addingTimeInterval(60), accountID: "A")
        let account = BenchmarkAccountSession(configuration: config, browser: ReviewBrowser(), transport: http, tokenStore: tokens, now: { http.now })
        await account.restore()
        let controller = BenchmarkController(account: account, store: try BenchmarkSyncStore(directory: root))
        let performance = PerformanceController(directory: root, fixture: true)
        performance.recorder!.enabled = true; controller.attach(performance: performance)
        controller.setFutureSync(true)
        let agent = PerformanceAgent(id: "fixture", name: "Fixture", connection: .cli)
        performance.capture { _ = try $0.beginTurn(comparisonID: "comparison", agent: agent, text: "Fixture prompt", scope: .shared) }
        http.holdRegistration = true
        let upload = Task { await controller.upload(events: performance.events, comparisonID: "comparison", context: "unknown") }
        while http.pending == nil { await Task.yield() }
        performance.capture { try $0.reply(comparisonID: "comparison", agent: agent, messageID: "reply", text: "Arrived during explicit upload", turnID: nil) }
        try await Task.sleep(for: .milliseconds(2300))
        guard http.registrations == 1, controller.working else { throw ReviewFailure.failed("Delayed autosync overlapped explicit upload; registrations=\(http.registrations)") }
        http.release(); await upload.value
        try await wait { controller.lineages.first?.selectedSequenceEnd == performance.events.count && controller.lineages.first?.finalized == true }
        guard controller.error == nil, controller.lineages.first!.chunks.count == 2, http.maxActive == 1 else { throw ReviewFailure.failed(controller.error ?? "Lost appended chunks or overlapping operations") }
        report("PASS: held manual upload crossed debounce; no overlap and later recording retained as exact continuation")
        controller.pause(); await controller.refreshRecords()
        guard controller.remoteRecords.count == 1, controller.acceptedComparisons == 1 else { throw ReviewFailure.failed("A presentation fixture did not load") }
        http.now = http.now.addingTimeInterval(120); http.rejectTokens = true
        do { _ = try await account.accessToken(accountID: "A"); throw ReviewFailure.failed("Expected rejected refresh") } catch BenchmarkAccountError.http(401) {}
        guard controller.remoteRecords.isEmpty, controller.contributionSummaries.isEmpty, controller.acceptedComparisons == nil else { throw ReviewFailure.failed("A presentation retained after permanent auth rejection") }
        http.rejectTokens = false; http.owner = "B"; await controller.signIn()
        guard account.account?.accountID == "B", controller.remoteRecords.isEmpty, controller.remotePublications.isEmpty, controller.acceptedComparisons == nil else { throw ReviewFailure.failed("B inherited A presentation") }
        http.holdPublications = true
        let reading = Task { await controller.refreshRecords() }
        while http.pending == nil { await Task.yield() }
        controller.signOut(); http.owner = "C"; await controller.signIn(); http.release(); await reading.value
        guard account.account?.accountID == "C", controller.remoteRecords.isEmpty, controller.acceptedComparisons == nil, !account.deletionOnly else { throw ReviewFailure.failed("Late B request mutated C presentation") }
        report("PASS: permanent auth failure and account switch clear all cloud presentation; late response cannot populate next account")
        let projection = try ComparisonPublicationBuilder.build(events: performance.events, comparisonID: "comparison")
        let approvedOwner = account.account!.accountID, approvedGeneration = account.generation
        http.holdPublications = true
        let publishing = Task { await controller.publish(projection, comparisonID: "comparison", owner: approvedOwner, accountGeneration: approvedGeneration) }
        while http.pending == nil { await Task.yield() }
        controller.signOut(); http.owner = "D"; await controller.signIn(); http.release(); await publishing.value
        guard controller.publicationLinks.isEmpty, controller.client!.store.publications.isEmpty else { throw ReviewFailure.failed("Late publication capability saved under new account") }
        let publicationRequests = http.publicationRequests
        await controller.publish(projection, comparisonID: "comparison", owner: approvedOwner, accountGeneration: approvedGeneration)
        guard http.publicationRequests == publicationRequests else { throw ReviewFailure.failed("Queued approved projection sent under another account") }
        report("PASS: publication approval captures owner/generation; late response and queued old approval cannot save or send under next account")
        controller.setFutureSync(true)
        performance.capture { _ = try $0.beginTurn(comparisonID: "delete-in-flight", agent: agent, text: "Delete during transmission", scope: .shared) }
        http.holdRegistration = true
        let inFlight = Task { await controller.upload(events: performance.events, comparisonID: "delete-in-flight", context: "unknown") }
        while http.pending == nil { await Task.yield() }
        let chunksBeforeDelete = http.chunkRequests
        performance.beforeDeleteRecords = { try controller.clearLocalUploads() }
        performance.deleteAll(); http.release(); await inFlight.value
        guard performance.events.isEmpty, controller.lineages.isEmpty, !controller.futureSync, http.chunkRequests == chunksBeforeDelete else { throw ReviewFailure.failed("Late registration after local deletion sent chunks or restored journal") }
        report("PASS: deleting local source during held transmission rejects late registration and sends no later chunks")
        controller.setFutureSync(true)
        let registrations = http.registrations
        performance.capture { _ = try $0.beginTurn(comparisonID: "delete-pending", agent: agent, text: "Pending local delete", scope: .shared) }
        performance.beforeDeleteRecords = { try controller.clearLocalUploads() }
        performance.deleteAll()
        try await Task.sleep(for: .milliseconds(2300))
        guard performance.events.isEmpty, controller.lineages.isEmpty, !controller.futureSync, controller.paused, http.registrations == registrations else { throw ReviewFailure.failed("Local deletion retained or transmitted pending uploads") }
        performance.recorder!.enabled = true
        performance.capture { _ = try $0.beginTurn(comparisonID: "preserve-on-clear-failure", agent: agent, text: "Keep original source", scope: .shared) }
        let original = performance.events
        let competing = try BenchmarkSyncStore(directory: root)
        try competing.pause(false)
        performance.deleteAll()
        guard performance.events == original, performance.error != nil else { throw ReviewFailure.failed("Source deleted despite stale upload journal clear failure") }
        report("PASS: local deletion clears outbox/ongoing consent and cancels pending debounce; journal-clear failure preserves source")
        controller.shutdown()
    }
    @MainActor static func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 { if predicate() { return }; try await Task.sleep(for: .milliseconds(100)) }
        throw ReviewFailure.failed("Timed out")
    }
}
enum ReviewFailure: Error { case failed(String) }
@MainActor final class ReviewBrowser: BenchmarkOAuthBrowser {
    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        let redirect = items.first { $0.name == "redirect_uri" }!.value!, state = items.first { $0.name == "state" }!.value!
        return URL(string: "\(redirect)?code=fixture&state=\(state)")!
    }
    func cancel() {}
}
@MainActor final class ReviewTokens: BenchmarkTokenStore {
    var token: BenchmarkAccountTokens?
    func read(scope: String) throws -> BenchmarkAccountTokens? { token }
    func save(_ tokens: BenchmarkAccountTokens, scope: String) throws { token = tokens }
    func delete(scope: String) throws { token = nil }
}
@MainActor final class ReviewHTTP: BenchmarkHTTPTransport {
    var now = Date(), owner = "A"
    var rejectTokens = false, holdRegistration = false, holdPublications = false
    var registrations = 0, chunkRequests = 0, publicationRequests = 0, active = 0, maxActive = 0, sequenceEnd = 0, hash = ""
    var pending: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    var held: URLRequest?
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        active += 1; maxActive = max(maxActive, active); defer { active -= 1 }
        if request.url!.path == "/api/v1/sessions", request.httpMethod == "POST" {
            registrations += 1
            if holdRegistration { held = request; return try await withCheckedThrowingContinuation { pending = $0 } }
        }
        if request.url!.path == "/api/v1/publications", request.httpMethod == "POST" { publicationRequests += 1 }
        if request.url!.path == "/api/v1/publications", holdPublications { held = request; return try await withCheckedThrowingContinuation { pending = $0 } }
        return try response(request)
    }
    func response(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let path = request.url!.path
        var value: Any = ["ok": true], status = 200
        if path == "/oauth/token" {
            status = rejectTokens ? 401 : 200
            value = ["access_token": owner, "refresh_token": "refresh-" + owner, "expires_in": 3600, "token_type": "Bearer"]
        } else if path == "/api/v1/account" { value = ["accountID": owner, "identity": "Synthetic"] }
        else if path == "/api/v1/sessions" { value = request.httpMethod == "POST" ? ["id": "cloud-session"] as Any : [["id": "cloud-session", "local_id": "comparison", "status": "complete", "fixture": 1]] }
        else if path.hasSuffix("/revisions") { value = ["revision": 2] }
        else if path.hasSuffix("/chunks") {
            chunkRequests += 1
            let chunk = try JSONDecoder().decode(PerformanceUploadChunk.self, from: request.httpBody!)
            sequenceEnd = chunk.sequenceEnd; hash = PerformanceCanonical.hash(request.httpBody!)
            value = ["id": chunk.id, "hash": hash]
        } else if path.hasSuffix("/finalize") {
            let revision = Int(path.split(separator: "/").dropLast().last!)!
            value = ["sessionID": "cloud-session", "revision": revision, "snapshotID": "head-\(revision)", "sequenceEnd": sequenceEnd, "hash": hash, "status": "pending-validation"]
        } else if path == "/api/v1/contributions" { value = ["history": [["session": "cloud-session", "revision": 1, "snapshotID": "head-1", "status": "accepted", "reasons": []]], "acceptedDistinctSessions": 1] }
        else if path == "/api/v1/publications" {
            if request.httpMethod == "POST" {
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                value = ["id": "pub", "path": "/s/synthetic", "projectionHash": body["previewHash"]!]
            } else { value = [["id": "pub", "created_at": "synthetic", "revoked_at": NSNull()]] }
        }
        return (try JSONSerialization.data(withJSONObject: value), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
    func release() { let continuation = pending!, request = held!; pending = nil; held = nil; holdRegistration = false; holdPublications = false; continuation.resume(with: Result { try response(request) }) }
    func cancelAll() {}
}
