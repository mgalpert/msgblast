import SwiftUI
import UIKit
import msgblastMobileKit
import msgblastRemoteProtocol

@main
struct MsgblastMobileApp: App {
    @StateObject private var app = MsgblastMobileApp.makeModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var incomingLink: String?
    @State private var backgroundFinish = BackgroundFinish()
    /// Debug design-review fixtures run with no network and no lifecycle connection.
    private static var designFixture: Bool {
        #if DEBUG
        DesignFixtures.current != nil
        #else
        false
        #endif
    }
    private static var launchScreen: LaunchScreen {
        #if DEBUG
        if let fixture = DesignFixtures.current { return DesignFixtures.screen(fixture) }
        #endif
        return .inbox
    }

    var body: some Scene {
        WindowGroup {
            RootView(app: app, incomingLink: $incomingLink, launchScreen: Self.launchScreen)
                .onOpenURL { url in if url.scheme == RemotePairingOffer.scheme { incomingLink = url.absoluteString } }
                .onChange(of: scenePhase) { _, phase in
                    guard !Self.designFixture else { return }
                    switch phase {
                    // `connect()` keeps a session that is still up, so coming back never loses a send in flight.
                    case .active: backgroundFinish.resume(); app.connection.startBrowsing(); app.connection.connect()
                    case .background:
                        app.store.saveNow()
                        if app.hasPendingSends { backgroundFinish.begin(app) } else { app.connection.stop() }
                    default: break
                    }
                }
                .task {
                    // Simulator and UX iteration: `-pairLink msgblast://pair?offer=…` pairs at launch.
                    if let link = UserDefaults.standard.string(forKey: "pairLink"), app.connection.pairedMac == nil { incomingLink = link }
                }
        }
    }

    @MainActor static func makeModel() -> MobileApp {
        #if DEBUG
        if let fixture = DesignFixtures.current { return DesignFixtures.makeModel(fixture) }
        #endif
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("msgblast-remote", isDirectory: true)
        let database = (try? LocalDatabase(url: folder.appendingPathComponent("cache.sqlite"))) ?? (try! LocalDatabase(url: nil))
        return MobileApp(database: database, keys: KeychainDeviceKeyStore())
    }
}

/// Holds the session after backgrounding while a send still waits on the Mac, which sends the
/// result only to the session that asked. Saves and stops once nothing waits or after `limit`;
/// returning to the foreground first keeps the session up.
@MainActor
final class BackgroundFinish {
    private var token = UIBackgroundTaskIdentifier.invalid
    private var task: Task<Void, Never>?

    func begin(_ app: MobileApp, limit: Duration = .seconds(25)) {
        resume()
        token = UIApplication.shared.beginBackgroundTask(withName: "msgblast.pendingSends") { [weak self] in self?.finish(app) }
        task = Task { [weak self] in
            let deadline = ContinuousClock.now + limit
            while app.hasPendingSends && ContinuousClock.now < deadline && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(250)) }
            guard !Task.isCancelled else { return }
            self?.finish(app)
        }
    }

    /// Back in the foreground: the session stays, and iOS gets its task back.
    func resume() { task?.cancel(); task = nil; end() }

    private func finish(_ app: MobileApp) {
        task?.cancel(); task = nil
        app.store.saveNow()
        app.connection.stop()
        end()
    }

    private func end() {
        guard token != .invalid else { return }
        UIApplication.shared.endBackgroundTask(token)
        token = .invalid
    }
}
