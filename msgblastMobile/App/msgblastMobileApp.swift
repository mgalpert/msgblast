import SwiftUI
import msgblastMobileKit
import msgblastRemoteProtocol

@main
struct MsgblastMobileApp: App {
    @StateObject private var app = MsgblastMobileApp.makeModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var incomingLink: String?

    var body: some Scene {
        WindowGroup {
            RootView(app: app, incomingLink: $incomingLink)
                .onOpenURL { url in if url.scheme == RemotePairingOffer.scheme { incomingLink = url.absoluteString } }
                .onChange(of: scenePhase) { _, phase in
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
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("msgblast-remote", isDirectory: true)
        let database = (try? LocalDatabase(url: folder.appendingPathComponent("cache.sqlite"))) ?? (try! LocalDatabase(url: nil))
        return MobileApp(database: database, keys: KeychainDeviceKeyStore())
    }
}
