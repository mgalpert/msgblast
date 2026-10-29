import Foundation

enum DesktopAppWorkflow {
    struct ReplyClock: Clock {
        typealias Instant = ContinuousClock.Instant
        private let readNow: @Sendable () -> Instant
        private let suspend: @Sendable (Instant, Duration?) async throws -> Void
        let minimumResolution: Duration
        init<C: Clock>(_ clock: C) where C.Instant == Instant, C.Duration == Duration {
            readNow = { clock.now }
            suspend = { try await clock.sleep(until: $0, tolerance: $1) }
            minimumResolution = clock.minimumResolution
        }
        var now: Instant { readNow() }
        func sleep(until deadline: Instant, tolerance: Duration?) async throws { try await suspend(deadline, tolerance) }
    }
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
        if error is MuseObservationError || error is DesktopAccessibilityError || error is ClaudeObservationError || error is ChatGPTObservationError || error is GeminiObservationError || error is WabiObservationError { return true }
        if case DesktopAppError.incompleteSnapshot = error { return true }
        return false
    }

    static func connection<Value: Sendable>(_ app: DesktopAppProvider, driver: DesktopAppConversation?,
                                           isolation: isolated (any Actor)? = #isolation,
                                           check: () async throws -> Value) async throws -> Value {
        do { return try await check() }
        catch {
            guard transient(error), let driver,
                  let focus = try await driver.beginForeground(app, session: "msgblast-connect-\(UUID())") else { throw error }
            let result: Value
            do { result = try await check() }
            catch {
                try await focus.restore()
                throw error
            }
            try await focus.restore()
            return result
        }
    }

    /// Navigation needed for a send runs under the same foreground ownership
    /// as input, so a background click cannot silently leave the old chat open.
    static func preparation<Value: Sendable>(_ app: DesktopAppProvider, driver: DesktopAppConversation?,
                                            isolation: isolated (any Actor)? = #isolation,
                                            prepare: () async throws -> Value) async throws -> Value {
        guard let driver, let focus = try await driver.beginForeground(app, session: "msgblast-prepare-\(UUID())") else {
            return try await prepare()
        }
        let value: Value
        do { value = try await prepare() }
        catch {
            try await focus.restore()
            throw error
        }
        try await focus.restore()
        return value
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
                      onSubmitAction: () async -> Void = {},
                      releaseFocus: () async throws -> Void = {},
                      continueWaiting: () -> Bool = { false },
                      submit: () async throws -> Void, observe: () async throws -> String?) async throws -> String where C.Duration == Duration {
        try Task.checkCancellation()
        try await submit()
        await onSubmitAction()
        var deadline = clock.now.advanced(by: timeout ?? timing.replyTimeout)
        let focusDeadline = clock.now.advanced(by: .seconds(5))
        var releasedFocus = false
        var previous: String?, since = clock.now
        while clock.now < deadline || continueWaiting() {
            if clock.now >= deadline { deadline = clock.now.advanced(by: timeout ?? timing.replyTimeout) }
            try await clock.sleep(for: timing.pollInterval)
            if !releasedFocus, clock.now >= focusDeadline {
                try await releaseFocus()
                releasedFocus = true
            }
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
