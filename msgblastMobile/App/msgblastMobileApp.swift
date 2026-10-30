import SwiftUI
import msgblastMobileKit
import msgblastRemoteProtocol

@main
struct MsgblastMobileApp: App {
    @StateObject private var app = MsgblastMobileApp.makeModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var incomingLink: String?
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
                    case .active: app.connection.startBrowsing(); app.connection.connect()
                    case .background: app.store.saveNow(); app.connection.stop()
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
