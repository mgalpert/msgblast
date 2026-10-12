import Foundation
import msgblastCore

/// Real storage and form controllers with temporary files and injected feedback transport.
/// This fixture never opens a feedback connection, a save panel, or live Messages.
@MainActor enum StorageFeedbackChecks {
    static func run() async throws {
        try attachmentReferences()
        try failedDraftSave()
        try await feedbackLifecycle()
    }

    private static func attachmentReferences() throws {
        let store = LocalStore(demo: true, isolated: true)
        let root = store.url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let memberID = UUID()
        let member = Member(agentID: memberID, name: "Fixture", chat: Chat(id: "fixture", handle: "fixture@example.com", lastActivity: 0))
        let references: [(String, (inout AppState, MessageAttachment) -> Void)] = [
            ("main draft", { $0.attachmentsDraft = [$1] }),
            ("comparison original", { $0.comparisons[0].attachments = [$1] }),
            ("shared context", { $0.comparisons[0].sharedContext = [ConversationContextMessage(text: "Shared", attachments: [$1])] }),
            ("shared draft", { $0.comparisons[0].allAttachmentsDraft = [$1] }),
            ("private draft", { $0.comparisons[0].privateAttachmentDrafts = [memberID.uuidString: [$1]] }),
            ("member payload", { $0.comparisons[0].members[0].payload = OutgoingPayload(text: "", attachments: [$1]) }),
            ("follow-up payload", { state, file in
                var followUp = FollowUp(text: "Follow-up", memberIDs: [memberID])
                followUp.payloads = [memberID.uuidString: OutgoingPayload(text: "", attachments: [file])]
                state.comparisons[0].followUps = [followUp]
            })
        ]
        for (name, reference) in references {
            let contents = Data("Staged attachment for \(name)".utf8)
            let file = try store.stage(contents, filename: "fixture.txt")
            var state = AppState()
            state.comparisons = [Comparison(prompt: "Fixture", members: [member])]
            reference(&state, file)
            // Use a persisted round-trip so transient-only fields cannot accidentally protect a file.
            try store.save(state)
            store.removeUnreferenced(file, in: try store.load())
            let retained = try Data(contentsOf: file.url)
            precondition(retained == contents, "Lost attachment referenced by \(name)")
            try store.save(AppState())
            store.removeUnreferenced(file, in: try store.load())
            precondition(!FileManager.default.fileExists(atPath: file.url.deletingLastPathComponent().path), "Final \(name) reference did not release the staged directory")
        }
        let outside = root.appendingPathComponent("outside.txt")
        let contents = Data("Outside staging ownership".utf8)
        try contents.write(to: outside)
        let foreign = MessageAttachment(id: UUID().uuidString, filename: "outside.txt", path: outside.path)
        store.removeUnreferenced(foreign, in: AppState())
        let preserved = try Data(contentsOf: outside)
        precondition(preserved == contents, "Garbage collection removed an unowned path")
        print("PASS: LocalStore retains each persisted draft/context/payload reference, removes the last reference, and leaves outside paths intact.")
    }

    private static func failedDraftSave() throws {
        let model = AppModel()
        model.timer?.invalidate()
        let root = model.local.url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = Data("Draft survives failed save".utf8)
        let file = try model.local.stage(contents, filename: "draft.txt")
        model.setAttachmentDraft([file])
        precondition(model.state.attachmentsDraft?.map(\.id) == [file.id])
        let saved = try Data(contentsOf: model.local.url)
        // A directory at state.json deterministically rejects atomic replacement, including as root.
        try FileManager.default.removeItem(at: model.local.url)
        try FileManager.default.createDirectory(at: model.local.url, withIntermediateDirectories: false)
        let sentinel = model.local.url.appendingPathComponent("saved-state.json")
        try saved.write(to: sentinel)
        model.error = nil
        model.setAttachmentDraft([])
        precondition(model.error != nil, "Fixture did not reach the save failure")
        let preserved = try Data(contentsOf: file.url)
        precondition(preserved == contents, "Failed draft save deleted a recoverable attachment")
        // Restore the old saved draft: it must still point to the intact staged attachment.
        try FileManager.default.removeItem(at: model.local.url)
        try saved.write(to: model.local.url)
        let recovered = try model.local.load()
        precondition(recovered.attachmentsDraft?.map(\.id) == [file.id])
        model.state = recovered
        model.setAttachmentDraft([])
        precondition(!FileManager.default.fileExists(atPath: file.url.path), "Successful final draft save should release the file")
        let cleared = try model.local.load()
        precondition(cleared.attachmentsDraft?.isEmpty == true)
        print("PASS: actual AppModel.setAttachmentDraft preserves staged bytes after a failed save and releases them only after a successful persisted removal.")
    }

    private static func feedbackLifecycle() async throws {
        let transport = FeedbackFixtureTransport()
        let session = FeedbackSession(facts: .empty(), submit: transport.submit)
        precondition(session.includeDiagnostics && !session.canSend)
        session.note = "Fixture feedback"
        precondition(session.canSend)
        precondition(transport.attempts.isEmpty, "Editing a note must not submit feedback")
        session.send()
        precondition(session.isSending && !session.canSend)
        session.send()
        try await waitUntil { transport.attempts.count == 1 }
        precondition(transport.attempts[0].request.note == "Fixture feedback")
        precondition(transport.attempts[0].request.includeDiagnostics)
        transport.finish(.failure(FeedbackSubmissionError.unavailable))
        try await waitUntil { !session.isSending }
        precondition(session.canSend && session.note == "Fixture feedback")
        precondition(session.message != nil)
        session.send()
        try await waitUntil { transport.attempts.count == 2 }
        precondition(transport.attempts[1].id == transport.attempts[0].id, "Unchanged retry must reuse the deduplication ID")
        transport.finish(.success(()))
        try await waitUntil { !session.isSending }
        precondition(!session.canSend && session.sendTitle == "Feedback sent")
        session.send()
        await Task.yield()
        precondition(transport.attempts.count == 2, "Sent feedback must not submit twice")
        session.note = "Changed fixture feedback"
        session.includeDiagnostics = false
        precondition(session.canSend)
        session.send()
        try await waitUntil { transport.attempts.count == 3 }
        precondition(transport.attempts[2].id != transport.attempts[1].id, "Changed request must get a new deduplication ID")
        precondition(!transport.attempts[2].request.includeDiagnostics)
        transport.finish(.success(()))
        try await waitUntil { !session.isSending }

        var cancellationObserved = false
        var submissionStarted = false
        let cancelling = FeedbackSession(facts: .empty()) { _, _, _, _ in
            submissionStarted = true
            do { try await Task.sleep(for: .seconds(30)) }
            catch { cancellationObserved = true; throw error }
            throw FeedbackSubmissionError.unavailable
        }
        cancelling.note = "Keep this note after closing"
        cancelling.contact = "fixture@example.com"
        cancelling.send()
        // Let the submission start before closing the window/session.
        try await waitUntil { submissionStarted }
        cancelling.cleanup()
        try await waitUntil { !cancelling.isSending }
        precondition(cancellationObserved)
        precondition(cancelling.note == "Keep this note after closing" && cancelling.contact == "fixture@example.com")
        precondition(cancelling.canSend)
        print("PASS: actual FeedbackSession requires explicit send, blocks in-flight/confirmed duplicates, reuses retry IDs, changes IDs with edited requests, and cancels without losing the note. Injected transport; no upload.")
    }

    private static func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("Storage/feedback fixture did not reach the expected state")
    }
}

@MainActor private final class FeedbackFixtureTransport {
    struct Attempt { let request: DiagnosticRequest; let id: UUID }
    var attempts: [Attempt] = []
    private var completion: CheckedContinuation<Void, Error>?

    func submit(_ request: DiagnosticRequest, _ id: UUID, _ endpoint: URL, _ fixture: Bool) async throws -> FeedbackReceipt {
        // The production session still resolves and validates its endpoint in the real transport.
        precondition(endpoint == FeedbackSubmission.productionEndpoint)
        attempts.append(Attempt(request: request, id: id))
        try await withCheckedThrowingContinuation { completion = $0 }
        let receipt = try JSONSerialization.data(withJSONObject: ["id": id.uuidString])
        return try FeedbackSubmission.receipt(from: receipt, statusCode: 201, id: id)
    }

    func finish(_ result: Result<Void, Error>) {
        precondition(completion != nil)
        let pending = completion
        completion = nil
        pending?.resume(with: result)
    }
}
