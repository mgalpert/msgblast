import AppKit
import Combine
import msgblastCore
@preconcurrency import Sparkle

// Controlled local model. The production AppLifecycle implementation is compiled unchanged.
@MainActor final class AppModel: ObservableObject {
    @Published var busy = false
    @Published var webBroadcastBusy = false
    var error: String?
    let personalAgent = FakePersonalAgent()
    let webAgents = FakeWebAgents()
    func saveForTermination() throws {}
}
@MainActor final class FakeWebAgents {
    let hasNativeRequests = false
    var hasConnectedWebSessions = false
    var flushed = false
    var shutdownStarted = false
    var failFlush = false
    func saveBrowserDrafts() async throws {
        try await Task.sleep(for: .milliseconds(60))
        if failFlush { throw NSError(domain: "IsolatedDraftStorage", code: 1) }
        flushed = true
    }
    func beginShutdown() { shutdownStarted = true }
    func cancelAndWait() async {}
}
@MainActor final class FakePersonalAgent {
    let running: Set<UUID> = []
    func beginShutdown() {}
    func cancelAndWait() async {}
}
@main struct WebLifecycleCheck {
    @MainActor static func main() async throws {
        let application = NSApplication.shared
        do {
            let model = AppModel(), lifecycle = AppLifecycle()
            lifecycle.configure(model: model)
            model.webBroadcastBusy = true
            precondition(lifecycle.applicationShouldTerminate(application) == .terminateLater)
            // Leave the controlled broadcast busy; no real quit is requested or completed.
        }
        do {
            let model = AppModel(), lifecycle = AppLifecycle()
            lifecycle.configure(model: model)
            model.webAgents.hasConnectedWebSessions = true
            var reply: Bool?
            lifecycle.terminationReplyHandler = { reply = $0; precondition(model.webAgents.flushed) }
            precondition(lifecycle.applicationShouldTerminate(application) == .terminateLater)
            precondition(reply == nil && !model.webAgents.flushed)
            for _ in 0..<50 where reply == nil { try await Task.sleep(for: .milliseconds(10)) }
            precondition(reply == true && model.webAgents.shutdownStarted)
        }
        do {
            let model = AppModel(), lifecycle = AppLifecycle()
            lifecycle.configure(model: model)
            model.webAgents.hasConnectedWebSessions = true
            model.webAgents.failFlush = true
            var reply: Bool?, displayedError = false
            lifecycle.terminationReplyHandler = { reply = $0 }
            lifecycle.saveErrorHandler = { _ in displayedError = true }
            precondition(lifecycle.applicationShouldTerminate(application) == .terminateLater)
            for _ in 0..<50 where reply == nil { try await Task.sleep(for: .milliseconds(10)) }
            precondition(reply == false && displayedError)
            precondition(!model.webAgents.shutdownStarted, "A failed save must leave the app usable")
        }
        print("PASS: ordinary idle web Quit waits for the draft flush; a failed flush cancels Quit before shutdown. Controlled replies; no actual app termination.")
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        let item = SUAppcastItem(dictionary: ["title":"Local fixture", "enclosure":["url":"https://example.invalid/fixture.zip","sparkle:version":"2"]])!
        let model = AppModel(), lifecycle = AppLifecycle()
        lifecycle.configure(model: model)
        var installs = 0
        model.webBroadcastBusy = true
        precondition(lifecycle.updater(controller.updater, shouldPostponeRelaunchForUpdate: item, untilInvokingBlock: { installs += 1 }))
        try await Task.sleep(for: .milliseconds(40))
        precondition(installs == 0)
        model.busy = true
        model.webBroadcastBusy = false
        try await Task.sleep(for: .milliseconds(40))
        precondition(installs == 0, "Native submission still blocks the update")
        model.busy = false
        try await Task.sleep(for: .milliseconds(40))
        precondition(installs == 1)
        model.webBroadcastBusy = true
        model.webBroadcastBusy = false
        try await Task.sleep(for: .milliseconds(40))
        precondition(installs == 1, "Pending install must run only once")
        print("PASS: web-only broadcast defers quit; update waits for web and native sends, resumes exactly once. No updater started, downloads, or app termination.")
    }
}
