import Foundation

enum DesktopAppWorkflow {
    enum Input: Equatable { case text(String), newline }
    struct TextStep {
        let input: Input
        let before: String
        let after: String
        let first: Bool
        let last: Bool
    }

    static func validateText(_ text: String) throws {
        guard !text.isEmpty, text.utf16.count <= 200_000,
              !text.unicodeScalars.contains(where: { ($0.value < 32 && $0.value != 10) || $0.value == 127 }) else {
            throw DesktopAppError.unavailable("Use plain text and line breaks for app prompts. Your draft was preserved.")
        }
    }

    static func enterText(_ text: String, isolation: isolated (any Actor)? = #isolation,
                          before: (TextStep) async throws -> Void,
                          perform: (TextStep) async throws -> Void,
                          after: (TextStep) async throws -> Void) async throws {
        try validateText(text)
        var inputs: [Input] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            var remaining = line[...]
            while !remaining.isEmpty {
                let end = remaining.index(remaining.startIndex, offsetBy: 256, limitedBy: remaining.endIndex) ?? remaining.endIndex
                inputs.append(.text(String(remaining[..<end])))
                remaining = remaining[end...]
            }
            if index < lines.count - 1 { inputs.append(.newline) }
        }
        var prefix = ""
        for (index, input) in inputs.enumerated() {
            try Task.checkCancellation()
            let appended: String
            switch input { case .text(let text): appended = text; case .newline: appended = "\n" }
            let step = TextStep(input: input, before: prefix, after: prefix + appended, first: index == 0, last: index == inputs.count - 1)
            try await before(step)
            try await perform(step)
            try await after(step)
            prefix = step.after
        }
    }

    static func transient(_ error: Error) -> Bool {
        if error is DesktopAccessibilityError || error is ClaudeObservationError || error is ChatGPTObservationError || error is GeminiObservationError || error is WabiObservationError { return true }
        if case DesktopAppError.incompleteSnapshot = error { return true }
        return false
    }

    static func wait<Value, C: Clock>(timeout: Duration, interval: Duration, failure: String,
                            retry: (Error) -> Bool = transient,
                            clock: C = ContinuousClock(),
                            isolation: isolated (any Actor)? = #isolation,
                            read: () async throws -> Value, ready: (Value) throws -> Bool) async throws -> Value where C.Duration == Duration {
        let deadline = clock.now.advanced(by: timeout)
        var lastError: Error?
        while clock.now < deadline {
            try Task.checkCancellation()
            do {
                let value = try await read()
                guard clock.now < deadline else { break }
                lastError = nil
                if try ready(value), clock.now < deadline { return value }
            } catch {
                guard retry(error), clock.now < deadline else { throw error }
                lastError = error
            }
            let pause = min(interval, clock.now.duration(to: deadline))
            if pause > .zero { try await clock.sleep(for: pause) }
        }
        try Task.checkCancellation()
        throw lastError ?? DesktopAppError.unavailable(failure)
    }

    static func reply<C: Clock>(app: String, timing: DesktopAppConversation.Timing, timeout: Duration? = nil,
                      clock: C = ContinuousClock(),
                      isolation: isolated (any Actor)? = #isolation,
                      submit: () async throws -> Void, observe: () async throws -> String?) async throws -> String where C.Duration == Duration {
        try Task.checkCancellation()
        try await submit()
        let deadline = clock.now.advanced(by: timeout ?? timing.replyTimeout)
        var previous: String?, since = clock.now
        while clock.now < deadline {
            try await clock.sleep(for: timing.pollInterval)
            let candidate: String?
            do { candidate = try await observe() }
            catch {
                guard transient(error) else { throw error }
                previous = nil; since = clock.now
                continue
            }
            if candidate != previous { previous = candidate; since = clock.now }
            if let candidate, !candidate.isEmpty, since.duration(to: clock.now) >= timing.stableDuration { return candidate }
        }
        throw DesktopAppError.unavailable("\(app) has not completed a verified reply. Review the native conversation; nothing will be resent automatically.")
    }
}
