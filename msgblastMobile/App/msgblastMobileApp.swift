import SwiftUI
import msgblastRemoteProtocol

@main
struct MsgblastMobileApp: App {
    var body: some Scene {
        WindowGroup {
            Text("msgblast · protocol v\(RemoteProtocol.version)")
        }
    }
}
