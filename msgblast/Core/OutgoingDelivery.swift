import Foundation

/// Owns durable submission ordering. Transport acceptance and a history receipt
/// are separate events: later parts wait for a receipt, and ambiguous attempts
/// remain quarantined until history reconciliation can resolve them.
@MainActor
public enum OutgoingDelivery {
    public static func deliver(
        _ original: OutgoingPayload,
        history: () throws -> [Message],
        claimedAnchors: (OutgoingPayload) -> Set<String>,
        validate: (OutgoingPart) throws -> Void,
        persist: (OutgoingPayload) throws -> Void,
        submit: (OutgoingPart) async throws -> Void,
        didReadHistory: ([Message]) -> Void,
        reportError: (Error) -> Void,
        now: () -> Date = { Date() },
        waitForReceipt: () async throws -> Void = { try await Task.sleep(for: .milliseconds(500)) }
    ) async -> OutgoingPayload {
        var payload = original
        do {
            payload.reconcile(in: try history(), excluding: claimedAnchors(payload))
            try persist(payload)
        } catch { reportError(error); return payload }
        guard payload.submission != .uncertain else { return payload }
        for p in payload.pendingIndices {
            // An accepted send is never repeated. Wait for its receipt before sending the next part.
            guard payload.parts[..<p].allSatisfy({ $0.state == .submitted && $0.anchor != nil }) else { break }
            var attempted = false
            do {
                try validate(payload.parts[p])
                payload.parts[p].baseline = try history().map(\.id).max() ?? 0
                payload.parts[p].attemptedAt = now()
                payload.parts[p].state = .sending; payload.parts[p].error = nil
                try persist(payload)
                attempted = true
                try await submit(payload.parts[p])
                payload.parts[p].state = .submitted
                payload.parts[p].error = "Submitted, awaiting a history receipt. Refresh to reconcile."
                try persist(payload)
                for _ in 0..<6 {
                    let fresh = try history()
                    payload.reconcile(in: fresh, excluding: claimedAnchors(payload))
                    didReadHistory(fresh)
                    if payload.parts[p].anchor != nil { break }
                    try await waitForReceipt()
                }
                try persist(payload)
                if payload.parts[p].anchor == nil { break }
            } catch {
                payload.parts[p].state = Submission.failure(afterAttempt: attempted, error: error)
                payload.parts[p].error = error.localizedDescription
                do { try persist(payload) } catch { reportError(error) }
                break
            }
        }
        return payload
    }
}
