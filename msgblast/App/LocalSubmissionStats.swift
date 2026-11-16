import Combine
import Foundation
import msgblastCore

@MainActor
final class LocalSubmissionStats: ObservableObject {
    enum Outcome: String, Codable {
        case submitted, failed, uncertain
    }

    struct Attempt: Codable, Identifiable {
        var id: UUID
        var comparisonID: UUID
        var turnID: UUID
        var isFollowUp: Bool
        var recipientID: String
        var targetIDs: [String]
        var outcome: Outcome
        var seconds: Double?
    }

    struct Turn: Sendable {
        let id: UUID
        let isFollowUp: Bool
        let targetIDs: [String]

        @TaskLocal static var current: Turn?
    }

    private struct Saved: Codable {
        var enabled = false
        var attempts: [Attempt] = []
    }

    @Published private var saved = Saved()
    @Published private(set) var error: String?
    private let url: URL
    private var revision = UUID()
    private var readable = true

    var enabled: Bool { saved.enabled }
    var attempts: [Attempt] { saved.attempts }

    init(directory: URL) {
        url = directory.appendingPathComponent("My Stats", isDirectory: true).appendingPathComponent("submissions.json")
        do {
            saved = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: url))
        } catch let failure as CocoaError where failure.code == .fileReadNoSuchFile {
            // A new profile starts with recording off.
        } catch {
            readable = false
            self.error = "Could not read local stats: \(error.localizedDescription)"
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != saved.enabled else { return }
        revision = UUID()
        var next = saved
        next.enabled = enabled
        save(next)
    }

    func clear() {
        revision = UUID()
        if !readable {
            do { try FileManager.default.removeItem(at: url) }
            catch { self.error = error.localizedDescription; return }
            readable = true
        }
        save(Saved(enabled: saved.enabled))
    }

    private func begin() -> ((Attempt) -> Void)? {
        guard enabled, readable, error == nil else { return nil }
        let revision = self.revision
        var finished = false
        return { [weak self] attempt in
            guard !finished, let self, self.revision == revision, self.enabled, self.error == nil else { return }
            finished = true
            var next = self.saved
            next.attempts.append(attempt)
            self.save(next)
        }
    }

    func beginWeb(comparisonID: UUID, recipient: WebAgentID) -> (@MainActor (UUID, WebSendStatus, Duration?) -> Void)? {
        guard let record = begin() else { return nil }
        let turn = Turn.current
        return { attemptID, status, duration in
            let outcome: Outcome
            switch status {
            case .waiting, .observed: outcome = .submitted
            case .notSent: outcome = .failed
            case .uncertain: outcome = .uncertain
            default: return
            }
            record(Attempt(id: attemptID, comparisonID: comparisonID, turnID: turn?.id ?? attemptID,
                           isFollowUp: turn?.isFollowUp ?? true, recipientID: recipient.id,
                           targetIDs: turn?.targetIDs ?? [recipient.id], outcome: outcome, seconds: duration.map(Self.seconds)))
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        let elapsed = duration.components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    }

    func begin(comparisonID: UUID, followUp: FollowUp? = nil, member: Member, targetIDs: [String]) -> ((Submission?) -> Void)? {
        guard let record = begin() else { return nil }
        let turnID = followUp?.id ?? comparisonID
        let targets = Turn.current?.targetIDs ?? attempts.first { $0.turnID == turnID && $0.recipientID == member.id.uuidString }?.targetIDs ?? targetIDs.sorted()
        let attemptID = UUID()
        let started = ContinuousClock.now
        return { status in
            let outcome: Outcome
            switch status {
            case .submitted: outcome = .submitted
            case .failed: outcome = .failed
            case .uncertain: outcome = .uncertain
            default: return
            }
            record(Attempt(id: attemptID, comparisonID: comparisonID, turnID: turnID, isFollowUp: followUp != nil,
                           recipientID: member.id.uuidString, targetIDs: targets, outcome: outcome,
                           seconds: Self.seconds(started.duration(to: .now))))
        }
    }

    private func save(_ next: Saved) {
        guard readable else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(next).write(to: url, options: .atomic)
            saved = next
            error = nil
        } catch {
            self.error = "Could not save local stats: \(error.localizedDescription)"
        }
    }
}
