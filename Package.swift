// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "msgblast", platforms: [.macOS("15.0"), .iOS("26.0")],
    products: [.executable(name: "msgblast", targets: ["msgblast"])],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
        .package(url: "https://github.com/steipete/SweetCookieKit", revision: "29e7af6bb71f1b624380ab556330e8be8f7ddd65")
    ],
    targets: [
        // Pure Foundation + CryptoKit wire contract, shared with the future iOS controller.
        .target(name: "msgblastRemoteProtocol", path: "msgblast/RemoteProtocol"),
        .testTarget(name: "msgblastRemoteProtocolTests", dependencies: ["msgblastRemoteProtocol"], path: "msgblastRemoteProtocolTests"),
        .target(name: "msgblastCore", dependencies: ["msgblastRemoteProtocol", .product(name: "SweetCookieKit", package: "SweetCookieKit")], path: "msgblast/Core", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "msgblast", dependencies: ["msgblastCore", "msgblastRemoteProtocol", .product(name: "Sparkle", package: "Sparkle")], path: "msgblast",
            exclude: ["Core", "RemoteProtocol", "Info.plist", "msgblast.entitlements", "msgblastDebug.entitlements", "AppIcon.icon", "AppIconDemo.icon", "AppIconColor.icon", "AppIconNested.icon"],
            resources: [.copy("Resources/Discover"), .copy("Resources/MuseAvatar.jpg"), .copy("Resources/WebAgentIcons"), .copy("Resources/Onboarding"), .copy("ThirdPartyNotices.txt")], linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(name: "msgblastTests", dependencies: ["msgblastCore", "msgblastRemoteProtocol"], path: "msgblastTests")
    ])
