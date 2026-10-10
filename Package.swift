// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "msgblast", platforms: [.macOS("15.0")],
    products: [.executable(name: "msgblast", targets: ["msgblast"])],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
        .package(url: "https://github.com/steipete/SweetCookieKit", revision: "29e7af6bb71f1b624380ab556330e8be8f7ddd65")
    ],
    targets: [
        .target(name: "msgblastCore", dependencies: [.product(name: "SweetCookieKit", package: "SweetCookieKit")], path: "msgblast/Core", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "msgblast", dependencies: ["msgblastCore", .product(name: "Sparkle", package: "Sparkle")], path: "msgblast",
            exclude: ["Core", "Info.plist", "msgblast.entitlements", "msgblastDebug.entitlements", "AppIcon.icon", "AppIconDemo.icon", "AppIconColor.icon", "AppIconNested.icon"],
            resources: [.copy("Resources/Discover"), .copy("Resources/MuseAvatar.jpg"), .copy("Resources/WebAgentIcons"), .copy("Resources/Onboarding"), .copy("ThirdPartyNotices.txt")], linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(name: "msgblastTests", dependencies: ["msgblastCore"], path: "msgblastTests")
    ])
