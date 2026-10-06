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
    func save() throws {}
}
@MainActor final class FakeWebAgents {
    let hasNativeRequests = false
    func beginShutdown() {}
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
