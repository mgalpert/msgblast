#if DEBUG
import CryptoKit
import Foundation
import UIKit
import msgblastMobileKit
import msgblastRemoteProtocol

/// Debug-only screens for design review without pairing or a network. Launch with
/// `MSGBLAST_FIXTURE` set to inbox, conversation, conversation-short, typing, incomplete, blocked, new, settings,
/// reconnecting, locked, pairing or pairing-paste (and optionally `MSGBLAST_FIXTURE_CONVERSATION=<uuid>`
/// and `MSGBLAST_FIXTURE_DRAFT=<text>` to pre-fill the composer).
/// Everything here is simulated; nothing is read from or sent to a Mac.
enum DesignFixtures {
    enum Name: String, CaseIterable { case inbox, conversation, conversationShort = "conversation-short", conversationPinned = "conversation-pinned", conversationMany = "conversation-many", typing, incomplete, blocked, new, settings, reconnecting, locked, pairing, pairingPaste = "pairing-paste" }

    static var current: Name? { ProcessInfo.processInfo.environment["MSGBLAST_FIXTURE"].flatMap(Name.init(rawValue:)) }

    static let now = Date()
    static let replyText = "Why trofie?"
    static let group = UUID(uuidString: "6F1C2B4A-0000-4000-8000-000000000001")!
    static let codexDirect = UUID(uuidString: "6F1C2B4A-0000-4000-8000-000000000002")!
    static let cedarDirect = UUID(uuidString: "6F1C2B4A-0000-4000-8000-000000000003")!
    static let unfinished = UUID(uuidString: "6F1C2B4A-0000-4000-8000-000000000004")!
    static let blockedConversation = UUID(uuidString: "6F1C2B4A-0000-4000-8000-000000000005")!
    static let shortConversation = UUID(uuidString: "6F1C2B4A-0000-4000-8000-000000000006")!
    static let manyConversation = UUID(uuidString: "6F1C2B4A-0000-4000-8000-000000000007")!
    static let cedar = "messages:6F1C2B4A-0000-4000-8000-0000000000C0"

    /// The screen the fixture opens on.
    static func screen(_ name: Name) -> LaunchScreen {
        let requested = ProcessInfo.processInfo.environment["MSGBLAST_FIXTURE_CONVERSATION"].flatMap(UUID.init(uuidString:))
        switch name {
        case .conversation, .typing: return .conversation(requested ?? group)
        case .conversationShort: return .conversation(requested ?? shortConversation)
        case .conversationPinned: return .conversation(requested ?? group)
        case .conversationMany: return .conversation(requested ?? manyConversation)
        case .incomplete: return .conversation(requested ?? unfinished)
        case .blocked: return .conversation(requested ?? blockedConversation)
        case .new: return .newConversation
        case .settings: return .settings
        case .pairingPaste: return .pastePairingLink
        case .inbox, .reconnecting, .locked, .pairing: return requested.map(LaunchScreen.conversation) ?? .inbox
        }
    }

    @MainActor static func makeModel(_ name: Name) -> MobileApp {
        let database = try! LocalDatabase(url: nil)
        if name != .pairing && name != .pairingPaste {
            database.setValue(PairedMac(macName: "Studio Mac", variant: .production, deviceID: UUID(), identityKey: Data((0..<65).map { UInt8($0 &* 37 & 0xFF) }),
                                        spkiSHA256: Data(repeating: 7, count: 32), addresses: [], port: 52000, pairedAt: now.addingTimeInterval(-9 * 86_400)), "pairedMac")
            database.setValue(projection(name), "projection")
        }
        let defaults = UserDefaults(suiteName: "msgblast-design-fixtures")!
        let app = MobileApp(database: database, keys: MemoryDeviceKeyStore(), defaults: defaults)
        switch name {
        case .pairing, .pairingPaste: break
        case .reconnecting: app.connection.showDesignFixture(.reconnecting(attempt: 3, retryAt: now.addingTimeInterval(8)), lastHeard: now.addingTimeInterval(-130))
        case .locked: app.connection.showDesignFixture(.macLocked, lastHeard: now.addingTimeInterval(-40))
        default: app.connection.showDesignFixture(.connected, lastHeard: now, connectedVia: "100.101.102.103:52000", connectSeconds: 0.4)
        }
        if name != .pairing && name != .pairingPaste { for (_, avatar) in avatars { app.store.storeAvatar(avatar.data, for: avatar.ref) } }
        // `MSGBLAST_FIXTURE_DRAFT` pre-fills the opened conversation's composer, so Send shows.
        if let draft = ProcessInfo.processInfo.environment["MSGBLAST_FIXTURE_DRAFT"], case .conversation(let id) = screen(name) {
            app.store.setDraft(draft, for: MobileStore.draftKey(conversation: id, agentID: nil))
        }
        // Every row but the group has been read on this phone, so the inbox shows one unread dot.
        for id in [codexDirect, cedarDirect, unfinished, blockedConversation] { app.store.markOpened(id, at: now) }
        if name != .pairing && name != .pairingPaste {
            let command = RemoteCommand(action: .sendPrivate(conversationID: group, agentID: "claude", text: replyText, attachmentIDs: []))
            app.store.recordSent(command, at: now.addingTimeInterval(-50 * 60 + 119))
            app.store.handle(.commandResult(RemoteCommandResult(clientCommandID: command.clientCommandID, outcome: .applied, conversationID: group)))
            app.store.recordReply(command.clientCommandID, quoting: "\(group)-r1")
        }
        return app
    }

    // MARK: Projection

    static func projection(_ name: Name) -> ProjectionState {
        var state = ProjectionState()
        state.seq = 42
        state.macLocked = name == .locked
        state.macStatus = MacStatus(macName: "Studio Mac", variant: .production, locked: name == .locked, awake: true, databaseAvailable: true, databaseStatus: "Connected",
                                    messagesBusy: false, broadcastBusy: false, sendingAgentIDs: ["codexCLI"], keepAwakeEnabled: true, keepAwakeHeld: name != .locked,
                                    messagesSendsAllowed: true, observedAt: now)
        let museBlocked = name == .incomplete
        let agents = [
            agent("claude", .claude, .website, "Claude", .ready, []),
            agent("chatgptApp", .chatgpt, .macApp, "ChatGPT", .readyWillLaunch, [reason(.appNotRunning, "Opens ChatGPT on your Mac", .none)]),
            agent("museApp", .muse, .macApp, "Muse", museBlocked ? .blocked : .ready, museBlocked
                  ? [reason(.incompleteRequestBlocking, "Finish the Muse request first", .phone,
                            detail: "An earlier request to Muse did not complete. Review it before sending again; usage may have been consumed.")]
                  : []),
            agent("codexCLI", .chatgpt, .cli, "Codex CLI", .busy(detail: "Codex CLI is working…"), [reason(.sendInFlight, "Codex CLI is handling a request", .none)]),
            agent("dotsApp", .dots, .macApp, "Dots", .blocked, [reason(.permissionMissing, "Allow Accessibility on your Mac", .mac, permission: .accessibility,
                                                                      detail: "Allow Accessibility for msgblast in System Settings on your Mac.")]),
            agent("grok", .grok, .website, "Grok", .blocked, [reason(.signedOut, "Sign in to Grok on your Mac", .mac)]),
            agent("geminiApp", .gemini, .macApp, "Gemini", .unavailable, [reason(.notOfferedInBuild, "Gemini isn't in this version", .none,
                                                                                  detail: "Gemini is not offered in this version of msgblast.")]),
            agent(cedar, .messages, .messages, "Cedar", .ready, []),
        ]
        for var agent in agents {
            // Cedar keeps initials, so both the artwork and the fallback are on screen.
            agent.avatarRef = avatars[agent.agentID]?.ref
            state.agents[agent.agentID] = agent; state.agentOrder.append(agent.agentID)
        }
        state.grid = ["claude", "chatgptApp", "museApp", "codexCLI", "dotsApp", "grok", "geminiApp", cedar]

        // A group of three: every chip state across two of your messages, replies, one Mac app failure.
        let t0 = now.addingTimeInterval(-50 * 60)
        conversation(&state, group, "Best pasta shape for pesto?", ["claude", "chatgptApp", "museApp"], created: t0, last: now.addingTimeInterval(-4 * 60))
        user(&state, group, "p1", "Best pasta shape for pesto? One answer each.", at: t0)
        attempt(&state, group, "claude", "Best pasta shape for pesto? One answer each.", .observed, at: t0)
        attempt(&state, group, "chatgptApp", "Best pasta shape for pesto? One answer each.", .observed, at: t0)
        attempt(&state, group, "museApp", "Best pasta shape for pesto? One answer each.", .notSent, at: t0,
                detail: "App control could not complete this request. Review msgblast permissions; nothing will be retried automatically.")
        reply(&state, group, "claude", "r1", "Trofie. Its twists hold pesto better than anything else, and it is the Ligurian classic.", at: t0.addingTimeInterval(40))
        reply(&state, group, "claude", "r1b", "Fusilli is a close second.", at: t0.addingTimeInterval(45))
        reply(&state, group, "chatgptApp", "r2", "Trofie or trenette. If you can't find those, use fusilli.", at: t0.addingTimeInterval(55))
        // A reply from this phone to Claude's first answer (a private send; the quote is local).
        user(&state, group, "q1", Self.replyText, at: t0.addingTimeInterval(120), agent: "claude")
        attempt(&state, group, "claude", Self.replyText, .observed, at: t0.addingTimeInterval(120))
        reply(&state, group, "claude", "r3", "Its tight twists trap the sauce in every bite.", at: t0.addingTimeInterval(150))
        let t1 = now.addingTimeInterval(-4 * 60)
        user(&state, group, "p2", "What about gnocchi?", at: t1)
        attempt(&state, group, "claude", "What about gnocchi?", .sending, at: t1)
        attempt(&state, group, "chatgptApp", "What about gnocchi?", .submitted, at: t1)
        attempt(&state, group, "museApp", "What about gnocchi?", .uncertain, at: t1, detail: "Outgoing message observed in the app. Waiting for its reply.")

        // Direct: two commands without a confirmed result.
        let t2 = now.addingTimeInterval(-26 * 3600)
        conversation(&state, codexDirect, "Rename the build script", ["codexCLI"], created: t2, last: t2.addingTimeInterval(300), unresolved: 2)
        user(&state, codexDirect, "c1", "Rename build.sh to package.sh and update the docs.", at: t2, agent: "codexCLI")
        reply(&state, codexDirect, "codexCLI", "c2", "Renamed it and updated three references in docs/.", at: t2.addingTimeInterval(120))

        // Direct, ended, with a photo.
        let t3 = now.addingTimeInterval(-9 * 86_400)
        conversation(&state, cedarDirect, "Dinner Friday?", [cedar], created: t3, last: t3.addingTimeInterval(600), ended: t3.addingTimeInterval(900))
        user(&state, cedarDirect, "m1", "Dinner Friday? This place looks good.", at: t3, agent: cedar,
             attachments: [RemoteAttachmentRef(id: "a1", filename: "Menu.jpg", mimeType: "image/jpeg", byteCount: 240_000)])
        attempt(&state, cedarDirect, cedar, "Dinner Friday? This place looks good.", .submitted, at: t3)
        reply(&state, cedarDirect, cedar, "m2", "Yes! 7:30?", at: t3.addingTimeInterval(600))

        if name == .incomplete {
            let t4 = now.addingTimeInterval(-90)
            conversation(&state, unfinished, "Weekend in Lisbon", ["museApp", "chatgptApp"], created: t4, last: t4, unresolved: 2,
                         incomplete: [RemoteIncompleteAttempt(agentID: "museApp", attemptID: "wa:11111111-0000-4000-8000-000000000001", reasonCode: .incompleteRequestBlocking),
                                      RemoteIncompleteAttempt(agentID: "chatgptApp", attemptID: "wa:11111111-0000-4000-8000-000000000002", reasonCode: .incompleteRequestBlocking)])
            user(&state, unfinished, "w1", "Plan two days in Lisbon.", at: t4)
            state.attempts["wa:11111111-0000-4000-8000-000000000001"] = RemoteAttempt(id: "wa:11111111-0000-4000-8000-000000000001", conversationID: unfinished, agentID: "museApp",
                text: "Plan two days in Lisbon.", status: .attempting, detail: "Outgoing message observed in the app. Waiting for its reply.", created: t4)
            state.attempts["wa:11111111-0000-4000-8000-000000000002"] = RemoteAttempt(id: "wa:11111111-0000-4000-8000-000000000002", conversationID: unfinished, agentID: "chatgptApp",
                text: "Plan two days in Lisbon.", status: .uncertain, detail: "ChatGPT stopped answering before its reply finished.", created: t4)
        }
        if name == .conversationPinned {
            // A longer group thread, so the first prompt scrolls away and the pinned row shows.
            let more = ["Which olive oil?", "Pine nuts or walnuts?", "How much garlic?", "Pecorino or Parmigiano?"]
            for (index, question) in more.enumerated() {
                let at = now.addingTimeInterval(Double(-30 + index * 5) * 60)
                user(&state, group, "q\(index)", question, at: at)
                attempt(&state, group, "claude", question, .observed, at: at)
                reply(&state, group, "claude", "a\(index)", "For \(question.lowercased().dropLast()) keep it simple: use what tastes good raw.", at: at.addingTimeInterval(30))
            }
        }
        if name == .conversationMany {
            // Six agents, so the agent tabs scroll.
            let t7 = now.addingTimeInterval(-20 * 60)
            let members = ["claude", "chatgptApp", "museApp", "codexCLI", "dotsApp", "grok"]
            conversation(&state, manyConversation, "Name for a bakery", members, created: t7, last: t7.addingTimeInterval(90))
            user(&state, manyConversation, "m0", "Suggest one name for a small neighborhood bakery.", at: t7)
            for (index, (agent, answer)) in [("claude", "Crumb & Co."), ("museApp", "Morning Proof"), ("codexCLI", "Flour Hour")].enumerated() {
                attempt(&state, manyConversation, agent, "Suggest one name for a small neighborhood bakery.", .observed, at: t7)
                reply(&state, manyConversation, agent, "m\(index + 1)", answer, at: t7.addingTimeInterval(Double(30 + index * 20)))
            }
        }
        if name == .conversationShort {
            // Like a real one-question Muse thread: one message and one reply.
            let t6 = now.addingTimeInterval(-6 * 60)
            conversation(&state, shortConversation, "Quiet Sunday", ["museApp"], created: t6, last: t6.addingTimeInterval(40))
            user(&state, shortConversation, "s1", "Plan a quiet Sunday in Lisbon.", at: t6, agent: "museApp")
            attempt(&state, shortConversation, "museApp", "Plan a quiet Sunday in Lisbon.", .observed, at: t6)
            reply(&state, shortConversation, "museApp", "s2", "Coffee in Príncipe Real, the Gulbenkian garden, then sunset at Miradouro da Senhora do Monte.", at: t6.addingTimeInterval(40))
        }
        if name == .blocked {
            let t5 = now.addingTimeInterval(-15 * 60)
            conversation(&state, blockedConversation, "Summarize this article", ["claude", "dotsApp"], created: t5, last: t5.addingTimeInterval(30))
            user(&state, blockedConversation, "b1", "Summarize this article in three bullets.", at: t5)
            attempt(&state, blockedConversation, "claude", "Summarize this article in three bullets.", .observed, at: t5)
            attempt(&state, blockedConversation, "dotsApp", "Summarize this article in three bullets.", .notSent, at: t5,
                    detail: "Allow Accessibility for msgblast in System Settings on your Mac.")
            reply(&state, blockedConversation, "claude", "b2", "• The study tracked 4,000 people\n• Sleep mattered more than diet\n• Effects showed after six weeks", at: t5.addingTimeInterval(30))
        }
        return state
    }

    /// Generated artwork: a 256-pt squircle with the agent's letter (no third-party art).
    static let avatars: [String: (ref: String, data: Data)] = {
        let looks: [(String, String, UIColor, UIColor)] = [
            ("claude", "C", UIColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1), UIColor(red: 0.70, green: 0.33, blue: 0.22, alpha: 1)),
            ("chatgptApp", "G", UIColor(red: 0.10, green: 0.10, blue: 0.10, alpha: 1), UIColor(red: 0.30, green: 0.30, blue: 0.30, alpha: 1)),
            ("museApp", "M", UIColor(red: 0.55, green: 0.36, blue: 0.96, alpha: 1), UIColor(red: 0.36, green: 0.20, blue: 0.80, alpha: 1)),
            ("codexCLI", ">", UIColor(red: 0.16, green: 0.20, blue: 0.27, alpha: 1), UIColor(red: 0.05, green: 0.07, blue: 0.10, alpha: 1)),
            ("dotsApp", "D", UIColor(red: 0.20, green: 0.55, blue: 0.98, alpha: 1), UIColor(red: 0.10, green: 0.35, blue: 0.85, alpha: 1)),
            ("grok", "X", UIColor(red: 0.90, green: 0.90, blue: 0.92, alpha: 1), UIColor(red: 0.62, green: 0.62, blue: 0.66, alpha: 1)),
            ("geminiApp", "✦", UIColor(red: 0.27, green: 0.52, blue: 0.96, alpha: 1), UIColor(red: 0.62, green: 0.38, blue: 0.95, alpha: 1)),
        ]
        var result: [String: (ref: String, data: Data)] = [:]
        for (id, letter, top, bottom) in looks {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let data = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256), format: format).pngData { context in
                let rect = CGRect(x: 0, y: 0, width: 256, height: 256)
                UIBezierPath(roundedRect: rect, cornerRadius: 58).addClip()
                let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [top.cgColor, bottom.cgColor] as CFArray, locations: [0, 1])!
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: 256), options: [])
                let dark = id == "grok"
                let text = NSAttributedString(string: letter, attributes: [.font: UIFont.systemFont(ofSize: 132, weight: .bold), .foregroundColor: dark ? UIColor.black : UIColor.white])
                let size = text.size()
                text.draw(at: CGPoint(x: (256 - size.width) / 2, y: (256 - size.height) / 2))
            }
            result[id] = ("sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), data)
        }
        return result
    }()

    private static func agent(_ id: String, _ product: AgentProduct, _ form: AgentForm, _ name: String, _ readiness: AgentReadiness, _ reasons: [AvailabilityReason]) -> AgentAvailability {
        AgentAvailability(agentID: id, product: product, form: form, displayName: name, visibleInGrid: true, selectedForSharedSend: readiness.acceptsSend,
                          capabilities: AgentCapabilities(sharedSend: true, privateSend: true, attachments: form == .messages, namedCopies: false, endConversation: true, sharesOneConversation: false),
                          readiness: readiness, reasons: reasons, observedAt: now, source: .live)
    }
    private static func reason(_ code: AvailabilityReasonCode, _ text: String, _ fix: FixLocation, permission: MacPermission? = nil, detail: String? = nil) -> AvailabilityReason {
        AvailabilityReason(code: code, userText: text, fixOn: fix, permission: permission, detail: detail)
    }
    private static func conversation(_ state: inout ProjectionState, _ id: UUID, _ title: String, _ agents: [String], created: Date, last: Date,
                                     unresolved: Int = 0, ended: Date? = nil, incomplete: [RemoteIncompleteAttempt] = []) {
        state.conversations[id] = RemoteConversation(id: id, title: title, prompt: title, created: created, endedAt: ended, agentIDs: agents, canEnd: true,
                                                     unresolvedAttemptCount: unresolved, lastActivity: last, incompleteAttempts: incomplete)
    }
    private static func user(_ state: inout ProjectionState, _ id: UUID, _ turn: String, _ text: String, at date: Date, agent: String? = nil, attachments: [RemoteAttachmentRef] = []) {
        state.turns["\(id)-\(turn)"] = RemoteTurn(id: "\(id)-\(turn)", conversationID: id, agentID: agent, role: .user, origin: agent == nil ? .sharedPrompt : .followUp,
                                                 text: text, created: date, ordinal: state.turns.count, attachments: attachments, contentHash: turn)
    }
    private static func reply(_ state: inout ProjectionState, _ id: UUID, _ agent: String, _ turn: String, _ text: String, at date: Date) {
        state.turns["\(id)-\(turn)"] = RemoteTurn(id: "\(id)-\(turn)", conversationID: id, agentID: agent, role: .assistant, origin: .agentTranscript,
                                                 text: text, created: date, ordinal: state.turns.count, contentHash: turn)
    }
    private static func attempt(_ state: inout ProjectionState, _ id: UUID, _ agent: String, _ text: String, _ status: RemoteAttemptStatus, at date: Date, detail: String? = nil) {
        let key = "\(id)-\(agent)-\(text.hashValue)"
        state.attempts[key] = RemoteAttempt(id: key, conversationID: id, agentID: agent, text: text, status: status, detail: detail, created: date)
    }
}
#endif

