import SwiftUI
import UIKit
import msgblastMobileKit
import msgblastRemoteProtocol

@main
struct MsgblastMobileApp: App {
    @StateObject private var launch = LaunchModel()
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
            Group {
                switch launch.state {
                case .ready(let app): RootView(app: app, incomingLink: $incomingLink, launchScreen: Self.launchScreen)
                case .loadFailed(let message):
                    LoadFailedView(message: message) {
                        launch.retry()
                        if let app = launch.app { app.connection.startBrowsing(); app.connection.connect() }
                    }
                }
            }
            .onOpenURL { url in if url.scheme == RemotePairingOffer.scheme { incomingLink = url.absoluteString } }
            .onChange(of: scenePhase) { _, phase in
                guard !Self.designFixture, let app = launch.app else { return }
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
                if let link = UserDefaults.standard.string(forKey: "pairLink"), let app = launch.app, app.connection.pairedMac == nil { incomingLink = link }
            }
        }
    }
}

/// Opens the saved state. A file that fails to load stays untouched (no empty stand-in is
/// written over it); the app shows the error and can try again.
@MainActor
final class LaunchModel: ObservableObject {
    @Published private(set) var state: MobileLaunch

    init() { state = Self.open() }

    var app: MobileApp? { if case .ready(let app) = state { app } else { nil } }

    func retry() { state = Self.open() }

    private static func open() -> MobileLaunch {
        #if DEBUG
        if let fixture = DesignFixtures.current { return .ready(DesignFixtures.makeModel(fixture)) }
        #endif
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("msgblast-remote", isDirectory: true)
        return MobileLaunch.open(databaseURL: folder.appendingPathComponent("cache.sqlite"), keys: KeychainDeviceKeyStore())
    }
}

struct LoadFailedView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Couldn't Open Saved Data", systemImage: "exclamationmark.triangle")
        } description: {
            VStack(spacing: 8) {
                Text("msgblast left the saved file on this iPhone unchanged.")
                Text(message).font(.footnote.monospaced()).textSelection(.enabled)
            }
        } actions: {
            Button("Try Again", action: retry).buttonStyle(.borderedProminent)
        }
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
