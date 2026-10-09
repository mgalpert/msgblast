import AppKit
import msgblastCore

@MainActor
enum AgentArtwork {
    private static var bundle: Bundle {
        #if SWIFT_PACKAGE
        Bundle.module
        #else
        Bundle.main
        #endif
    }

    static let grokBotImage: NSImage? = {
        guard let url = bundle.url(forResource: "grokbot", withExtension: "icns", subdirectory: "WebAgentIcons"),
              let source = NSImage(contentsOf: url) else { return nil }
        let size = NSSize(width: 256, height: 256)
        let sourceBounds = NSRect(origin: .zero, size: source.size)
        // The icon includes transparent margins around a rounded square. Crop to
        // its artwork before masking so its existing face fills a circular avatar.
        let crop = sourceBounds.insetBy(dx: source.size.width * 0.1, dy: source.size.height * 0.1)
        return NSImage(size: size, flipped: false) { bounds in
            NSBezierPath(ovalIn: bounds).addClip()
            NSColor(calibratedWhite: 0.2, alpha: 1).setFill()
            bounds.fill()
            source.draw(in: bounds, from: crop, operation: .sourceOver, fraction: 1)
            return true
        }
    }()

    static let grokBotAvatar: Data? = grokBotImage?.tiffRepresentation
    private static let messageAvatars: [OnboardingChoice: Data] = Dictionary(uniqueKeysWithValues:
        [OnboardingChoice.instinct, .fo, .szn].compactMap { choice in
            guard let url = bundle.url(forResource: choice.rawValue, withExtension: "jpg", subdirectory: "WebAgentIcons"),
                  let data = try? Data(contentsOf: url) else { return nil }
            return (choice, data)
        }
    )
    static func messageAvatar(for choice: OnboardingChoice) -> Data? { messageAvatars[choice] }
    private static let runtimeAvatars: [LocalAgentRuntime: Data] = Dictionary(uniqueKeysWithValues:
        LocalAgentRuntime.allCases.compactMap { runtime in
            guard let url = bundle.url(forResource: runtime.rawValue, withExtension: "png", subdirectory: "WebAgentIcons"),
                  let data = try? Data(contentsOf: url) else { return nil }
            return (runtime, data)
        }
    )
    static func runtimeAvatar(for runtime: LocalAgentRuntime) -> Data? { runtimeAvatars[runtime] }
    private static let museDefaultAvatar = bundle.url(forResource: "MuseAvatar", withExtension: "jpg")
        .flatMap { try? Data(contentsOf: $0) }
    private static let webDefaultAvatars: [WebProvider: Data] = Dictionary(uniqueKeysWithValues:
        [WebProvider.chatgpt, .claude, .grok, .codexCLI, .claudeCode, .dots].compactMap { provider in
            let resource = provider == .codexCLI ? "chatgpt" : provider == .claudeCode ? "claude" : provider.rawValue
            let fileExtension = provider == .dots ? "pdf" : provider == .grok ? "png" : "jpg"
            guard let url = bundle.url(forResource: resource, withExtension: fileExtension, subdirectory: "WebAgentIcons"),
                  let data = try? Data(contentsOf: url) else { return nil }
            return (provider, data)
        }
    )

    static func agent(for session: WebAgentSession) -> Agent {
        Agent(name: session.provider.name, handles: [],
              avatar: session.provider == .grokbot ? grokBotAvatar : session.avatar ?? (session.provider == .muse ? museDefaultAvatar : webDefaultAvatars[session.provider]),
              colorIndex: WebProvider.allCases.firstIndex(of: session.provider)! + 4)
    }
}
