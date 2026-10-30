#if DEBUG
import AppKit
import SwiftUI
import msgblastCore

/// Design review: a Debug-only request from `DesignFixture` that the workspace view
/// showing the named comparison acts on, exactly as if the reviewer had clicked.
enum DesignRequest: Equatable {
    case showDetails(UUID), hideDetails(UUID), send(UUID)
    var comparisonID: UUID {
        switch self { case .showDetails(let id), .hideDetails(let id), .send(let id): id }
    }
}

/// Design review: Debug-only launch arguments that render the conversation window in a
/// known fixture state and save it as PNG from inside the app. Demo (fixture) builds only:
/// nothing here reads Messages, contacts a provider, or sends anything.
///
/// - `--design-fixture side-chat|group|no-access` seeds Demo state and opens the workspace on it.
/// - `--appearance light|dark` sets the app appearance at launch.
/// - `--window-size WxH` sizes the captured window (centered) instead of the saved frame.
/// - `--capture-window <png>` saves one frame after `--capture-delay <seconds>` (default 3), then quits.
/// - `--capture-sequence <directory>` saves a numbered walkthrough of the fixture, then quits.
@MainActor enum DesignFixture {
    private static let flags = ["--design-fixture", "--appearance", "--window-size", "--capture-window", "--capture-delay", "--capture-sequence"]
    private static var arguments: [String] { ProcessInfo.processInfo.arguments }
    private static var isDemoLaunch: Bool {
        arguments.contains("--demo") || Bundle.main.object(forInfoDictionaryKey: "msgblastDemo") as? Bool == true
    }
    /// Any of the fixture or capture arguments is present.
    static var isRequested: Bool { flags.contains { arguments.contains($0) } }
    /// `no-access` reuses the app's own simulated Messages-history denial (`--permission-guide-preview`).
    static var simulatesMessagesDenial: Bool { isDemoLaunch && value(after: "--design-fixture") == Fixture.noAccess.rawValue }

    private enum Fixture: String { case sideChat = "side-chat", group, noAccess = "no-access" }
    private struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private static func value(after flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
    private static func report(_ message: String) {
        FileHandle.standardError.write(Data(("design-fixture: " + message + "\n").utf8))
    }

    static func appearance() -> NSAppearance? {
        guard isDemoLaunch else { return nil }
        switch value(after: "--appearance") {
        case "light": return NSAppearance(named: .aqua)
        case "dark": return NSAppearance(named: .darkAqua)
        default: return nil
        }
    }

    static func windowSize() -> NSSize? {
        guard isDemoLaunch, let text = value(after: "--window-size") else { return nil }
        let parts = text.lowercased().split(separator: "x")
        guard parts.count == 2, let width = Double(parts[0]), let height = Double(parts[1]), width >= 320, height >= 240 else { return nil }
        return NSSize(width: width, height: height)
    }

    private static var captureDelay: Double {
        value(after: "--capture-delay").flatMap { Double($0) }.map { max(0, $0) } ?? 3
    }

    static func run(model: AppModel) async {
        guard model.demo else {
            report("these launch arguments work only in the Demo (fixture) build; add --demo or use msgblast Demo")
            exit(2)
        }
        let fixture: Fixture?
        if let name = value(after: "--design-fixture") {
            guard let known = Fixture(rawValue: name) else { report("unknown --design-fixture \(name); use side-chat, group or no-access"); exit(2) }
            fixture = known
        } else { fixture = nil }
        if let appearance = value(after: "--appearance"), !["light", "dark"].contains(appearance) {
            report("--appearance takes light or dark"); exit(2)
        }
        if value(after: "--window-size") != nil, windowSize() == nil {
            report("--window-size takes WIDTHxHEIGHT, for example 1180x800"); exit(2)
        }
        if value(after: "--capture-sequence") != nil, fixture == nil {
            report("--capture-sequence needs --design-fixture side-chat|group|no-access"); exit(2)
        }
        do {
            try await waitForWindow()
            var comparisonID: UUID?
            if let fixture { comparisonID = try await seed(fixture, model: model) }
            if let directory = value(after: "--capture-sequence"), let fixture, let comparisonID {
                try await Task.sleep(for: .seconds(captureDelay))
                try await captureSequence(fixture, into: URL(fileURLWithPath: directory, isDirectory: true), model: model, comparisonID: comparisonID)
                exit(0) // Nothing to save: the fixture state is Demo-only and the window close confirmation would block terminate.
            } else if let path = value(after: "--capture-window") {
                try await Task.sleep(for: .seconds(captureDelay))
                try await capture(to: URL(fileURLWithPath: path), model: model, comparisonID: comparisonID)
                exit(0) // Nothing to save: the fixture state is Demo-only and the window close confirmation would block terminate.
            }
        } catch {
            report(error.localizedDescription)
            exit(1)
        }
    }

    // MARK: Seeding

    private static func waitForWindow() async throws {
        for _ in 0..<100 {
            if NSApp.windows.contains(where: { $0.isVisible }) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard NSApp.windows.contains(where: { $0.isVisible }) else { throw Failure("the main window did not appear") }
        try await Task.sleep(for: .milliseconds(500))
    }

    private static func seed(_ fixture: Fixture, model: AppModel) async throws -> UUID {
        switch fixture {
        case .sideChat: return try await seedSideChat(model: model)
        case .noAccess:
            guard model.permissionGuidePreview else { throw Failure("the simulated Messages-history denial is not active") }
            // The simulated denial would otherwise reopen onboarding; this fixture shows the workspace's status line.
            model.state.onboarding = nil
            model.persist()
            try await Task.sleep(for: .milliseconds(500))
            return try await seedSideChat(model: model)
        case .group: return try await seedGroup(model: model)
        }
    }

    private static func museSession(_ model: AppModel) throws -> WebAgentSession {
        guard let session = model.webAgents.session(for: WebAgentID(provider: .museApp)) else { throw Failure("the Muse app session is unavailable") }
        return session
    }

    /// Enable Muse and add it to the grid as Settings does, then connect the simulated
    /// desktop app the way Demo's own Connect button does.
    private static func connectMuse(_ session: WebAgentSession, model: AppModel) async throws {
        session.setEnabled(true)
        guard session.isEnabled else { throw Failure("Muse could not be enabled: \(session.desktopStatus)") }
        var grid = model.agentGridLayout
        grid.add(session.id.gridID)
        guard model.setAgentGrid(grid) else { throw Failure(model.error ?? "Muse could not be added to the agent grid") }
        guard await session.prepareDesktopConnection() else { throw Failure(session.error ?? session.desktopStatus) }
        await session.connectDesktopConversation()
        guard session.desktopReady else { throw Failure("Muse did not connect: \(session.desktopStatus)") }
    }

    private static let sideChatReply = """
        **Paper**: slow, sticks. Good for thinking, bad for finding.
        **Plain text files**: fast, searchable. Needs a naming habit.
        **A notes app**: synced, linkable. Easy to hoard, hard to prune.
        """
    private static let groupMuseReply = """
        **Same question, same rubric.** Ask each approach the same thing and score it on clarity, cost and reversibility.
        **Small example first.** Run all three on one concrete case before arguing in the abstract.
        **Decide what wins.** Name the outcome you want before you read any answer.
        """
    private static let simulatedDetail = "Simulated reply. No app, local CLI or provider was contacted."

    private static func seedSideChat(model: AppModel) async throws -> UUID {
        let session = try museSession(model)
        model.requestNewBlast()
        try await connectMuse(session, model: model)
        guard let id = await model.prepareWebComparison("Say OK", recipientIDs: [], agents: [session.id]) else {
            throw Failure(model.error ?? "the side chat comparison could not be created")
        }
        let now = Date()
        let first = WebPageMessage(role: "user", text: "Say OK")
        let second = WebPageMessage(role: "user", text: "Compare three ways to take notes, two lines each")
        var firstAttempt = WebSendAttempt(text: first.text, status: .observed)
        firstAttempt.messageID = first.id; firstAttempt.comparisonID = id; firstAttempt.detail = simulatedDetail
        firstAttempt.created = now.addingTimeInterval(-6 * 60)
        var secondAttempt = WebSendAttempt(text: second.text, status: .observed)
        secondAttempt.messageID = second.id; secondAttempt.comparisonID = id; secondAttempt.detail = simulatedDetail
        secondAttempt.created = now.addingTimeInterval(-2 * 60)
        session.updateState { state in
            // Seeded history needs a tracked side chat, or the pane reports untracked Muse history.
            try? state.recordMuseAppBinding(MuseSideChatBinding(comparisonID: id, threadID: UUID(), title: "Simulated side chat"))
            state.localConversations[id.uuidString] = [
                first, WebPageMessage(role: "assistant", text: "OK"),
                second, WebPageMessage(role: "assistant", text: sideChatReply)
            ]
            state.attempts.insert(contentsOf: [secondAttempt, firstAttempt], at: 0)
        }
        guard session.state.localConversations[id.uuidString]?.count == 4, (try? session.state.museAppBinding(for: id)) != nil else {
            throw Failure("the Muse session's saved state could not be seeded")
        }
        model.openWebComparison(id)
        // The Demo's sample draft would otherwise sit in the field; the fixture shows the placeholder.
        model.setSharedDraft("")
        try await Task.sleep(for: .milliseconds(500))
        return id
    }

    private static func seedGroup(model: AppModel) async throws -> UUID {
        let session = try museSession(model)
        model.requestNewBlast()
        try await connectMuse(session, model: model)
        let agents = ["Cedar", "Lumen", "Orbit"].compactMap { name in model.state.agents.first { $0.name == name } }
        guard agents.count == 3 else { throw Failure("the Demo agents Cedar, Lumen and Orbit are not all available") }
        model.state.selection = Set(agents.map(\.id))
        model.state.draft = "What is the clearest way to compare three approaches to the same problem?"
        model.persist()
        let existing = Set(model.state.comparisons.map(\.id))
        await model.start(recipientIDs: model.state.selection)
        guard let id = model.state.comparisons.first(where: { !existing.contains($0.id) })?.id else {
            throw Failure(model.error ?? "the Demo send did not create a comparison")
        }
        try await waitUntil(seconds: 15, "the Demo replies did not arrive") {
            guard let comparison = model.comparison(id) else { return false }
            return comparison.members.allSatisfy { member in model.transcript(comparison, member: member).contains { !$0.outgoing } }
        }
        guard let comparison = model.comparison(id) else { throw Failure("the comparison disappeared") }
        if let cedar = comparison.members.first(where: { $0.name == "Cedar" }) {
            model.appendDemo("If you only keep one of those, keep reversibility. It is the one you cannot recover later.", chat: cedar.chat, outgoing: false)
        }
        // Join Muse the way the Details popover does.
        model.coordinator?.prepareJoiningWebAgent(id)
        model.webBroadcastBusy = true
        model.webAgents.select(session, selected: true)
        session.connect()
        let joined = await model.joinWebAgent(session, comparisonID: id)
        model.webBroadcastBusy = false
        guard joined else { throw Failure(model.error ?? session.error ?? "Muse could not join the comparison") }
        session.updateState { state in
            var messages = state.localConversations[id.uuidString] ?? []
            if let last = messages.indices.last, messages[last].role == "assistant" { messages[last].text = groupMuseReply }
            state.localConversations[id.uuidString] = messages
        }
        try await Task.sleep(for: .milliseconds(500))
        return id
    }

    private static func waitUntil(seconds: Double, _ failure: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else { throw Failure(failure) }
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    // MARK: Capture

    private static var sizedWindows: Set<Int> = []

    private static func targetWindow(model: AppModel, comparisonID: UUID?) -> NSWindow? {
        if let comparisonID, let dedicated = NSApp.windows.first(where: { $0.isVisible && $0.identifier?.rawValue == comparisonID.uuidString + ":connected" }) {
            return dedicated
        }
        if let workspace = model.coordinator?.workspaceWindow, workspace.isVisible { return workspace }
        return NSApp.windows.first { $0.isVisible && $0.isMainWindow } ?? NSApp.windows.first { $0.isVisible }
    }

    private static func applyWindowSize(to window: NSWindow) async throws {
        guard let size = windowSize(), !sizedWindows.contains(window.windowNumber) else { return }
        sizedWindows.insert(window.windowNumber)
        let bounds = (window.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: size.width, height: size.height)
        let width = min(size.width, bounds.width), height = min(size.height, bounds.height)
        window.setFrame(NSRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height), display: true)
        try await Task.sleep(for: .milliseconds(300))
    }

    private static func capture(to url: URL, model: AppModel, comparisonID: UUID?) async throws {
        guard let window = targetWindow(model: model, comparisonID: comparisonID) else { throw Failure("no visible window to capture") }
        try await applyWindowSize(to: window)
        let title = comparisonID.flatMap { model.comparison($0)?.title } ?? "msgblast"
        let image = try await ChatWindowCapture.capture(window, title: title, layout: nil)
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { throw Failure("the capture could not be encoded as PNG") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: url, options: .atomic)
        print(url.path)
    }

    private static func captureSequence(_ fixture: Fixture, into directory: URL, model: AppModel, comparisonID id: UUID) async throws {
        var step = 0
        func frame(_ name: String) async throws {
            step += 1
            try await capture(to: directory.appendingPathComponent(String(format: "%02d-%@.png", step, name)), model: model, comparisonID: id)
        }
        func pause(_ seconds: Double = 2) async throws { try await Task.sleep(for: .seconds(seconds)) }
        let session = try museSession(model)
        switch fixture {
        case .group:
            try await frame("opened")
            try await pause()
            // Uncheck Lumen and Orbit as the header toggle does, leaving "Message Cedar".
            for agent in model.state.agents where ["Lumen", "Orbit"].contains(agent.name) { model.state.selection.remove(agent.id) }
            model.persist()
            try await pause()
            try await frame("filtered")
            try await pause()
            model.designRequest = .showDetails(id)
            try await pause()
            try await frame("details")
            try await pause()
            model.designRequest = .hideDetails(id)
            try await pause(0.5)
            model.setSharedDraft("Which of these would you actually use?")
            try await pause(1.5)
            try await frame("draft")
            try await pause()
            let cedar = model.comparison(id)?.members.first { $0.name == "Cedar" }
            let repliesBefore = cedar.flatMap { member in model.comparison(id).map { model.transcript($0, member: member).filter { !$0.outgoing }.count } } ?? 0
            model.designRequest = .send(id)
            try await pause(1.5)
            try await frame("sent")
            try await waitUntil(seconds: 15, "Cedar's Demo reply did not arrive") {
                guard let comparison = model.comparison(id), let cedar else { return false }
                return model.transcript(comparison, member: cedar).filter { !$0.outgoing }.count > repliesBefore && !model.busy && !model.webBroadcastBusy
            }
            try await pause(1)
            try await frame("replied")
        case .sideChat, .noAccess:
            try await frame("opened")
            try await pause()
            model.setSharedDraft("Which of these would you actually use?")
            try await pause()
            try await frame("draft")
            try await pause()
            let messagesBefore = session.state.localConversations[id.uuidString]?.count ?? 0
            model.designRequest = .send(id)
            try await pause(0.3)
            try await frame("sent")
            do {
                try await waitUntil(seconds: 15, "Muse did not answer") {
                    (session.state.localConversations[id.uuidString]?.count ?? 0) >= messagesBefore + 2 && !session.isSending && !model.webBroadcastBusy
                }
            } catch {
                // The fixture session normally answers on its own; keep the walkthrough complete if it did not.
                report("the fixture Muse session did not answer; appending a local reply")
                try await Task.sleep(for: .seconds(2))
                session.updateState { state in
                    var messages = state.localConversations[id.uuidString] ?? []
                    messages.append(WebPageMessage(role: "assistant", text: "I would use the plain text files: they are fast and searchable, and the naming habit pays for itself."))
                    state.localConversations[id.uuidString] = messages
                }
            }
            try await pause(1)
            try await frame("replied")
        }
    }
}
#endif
