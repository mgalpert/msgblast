// swift-tools-version: 6.0
// Command-line remote control client: the test harness and PR evidence vehicle
// until the iOS controller exists. Sources/msgblastRemoteProtocol is a symlink to
// msgblast/RemoteProtocol, so the client speaks exactly the app's protocol.
import PackageDescription
let package = Package(
    name: "msgblast-remote", platforms: [.macOS("15.0")],
    products: [.executable(name: "msgblast-remote", targets: ["msgblast-remote"])],
    targets: [
        .target(name: "msgblastRemoteProtocol", path: "Sources/msgblastRemoteProtocol"),
        // A small top-level-script CLI: Swift 5 mode keeps its globals simple; the protocol module stays Swift 6.
        .executableTarget(name: "msgblast-remote", dependencies: ["msgblastRemoteProtocol"], path: "Sources/msgblast-remote", swiftSettings: [.swiftLanguageMode(.v5)])
    ])
