import AppKit
import SwiftUI
import XCTest
@testable import msgblastCore

/// Settings → Outside agents adds an agent's row the moment the approval alert saves its level.
/// These host rows laid out like that page in a real window and check that building, redrawing
/// or closing the page never saves a level by itself.
@MainActor final class AgentAccessMenuTests: XCTestCase {
    func testMenuRowKeepsANewFullAccessApproval() {
        let levels = Levels()
        let writes = approve(levels, in: Rows(levels: levels))
        XCTAssertEqual(writes, [], "a row saved a level on its own")
        XCTAssertEqual(levels.approvals["Codex"], .full)
    }

    func testMenuRowKeepsANewApprovalAboveAnotherAgent() {
        let levels = Levels()
        let writes = approve(levels, in: Rows(levels: levels), existing: ["Evidence Agent": .full])
        XCTAssertEqual(writes, [], "a row saved a level on its own")
        XCTAssertEqual(levels.approvals, ["Codex": .full, "Evidence Agent": .full])
    }

    func testMenuSavesOnlyAChangedLevel() {
        XCTAssertEqual(AgentAccessMenu.choice(.full, picked: true, current: .readOnly), .full)
        XCTAssertEqual(AgentAccessMenu.choice(.readOnly, picked: true, current: .full), .readOnly)
        XCTAssertNil(AgentAccessMenu.choice(.full, picked: true, current: .full))
        XCTAssertNil(AgentAccessMenu.choice(.full, picked: false, current: .full))
    }

    /// Shows the page, then saves Full access for Codex while an alert-like window is key, closes that
    /// window so the page becomes key again, redraws a few times and closes the page, as the run that
    /// found the bug did with ⌘W. Returns every level the rows saved.
    private func approve(_ levels: Levels, in view: some View, existing: [String: AgentControlAccess] = [:]) -> [String] {
        levels.approvals = existing
        let page = window(NSHostingView(rootView: view), width: 680, height: 460)
        settle(0.6)
        let alert = window(NSView(), width: 300, height: 120)
        settle(0.2)
        levels.approvals["Codex"] = .full
        alert.close()
        page.makeKeyAndOrderFront(nil)
        settle(1.0)
        for _ in 0..<4 {
            levels.redraws += 1
            settle(0.25)
        }
        page.performClose(nil)
        settle(0.6)
        return levels.writes
    }

    private func window(_ content: NSView, width: CGFloat, height: CGFloat) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func settle(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
}

@MainActor private final class Levels: ObservableObject {
    @Published var approvals: [String: AgentControlAccess] = [:]
    @Published var redraws = 0
    private(set) var writes: [String] = []

    func save(_ level: AgentControlAccess, for client: String) {
        writes.append("\(client)=\(level.rawValue)")
        approvals[client] = level
    }
}

/// Settings → Outside agents → Agents as the page lays it out: Grok Bot first, then each agent
/// with its level menu and Remove.
private struct Rows: View {
    @ObservedObject var levels: Levels
    private let grokBot = "Grok Bot (Tailscale)"

    private var names: [String] { [grokBot] + levels.approvals.keys.sorted() }

    var body: some View {
        let _ = levels.redraws
        Form {
            Section("Agents") {
                ForEach(names, id: \.self) { client in
                    LabeledContent {
                        HStack(spacing: 8) {
                            if let level = levels.approvals[client] {
                                AgentAccessMenu(level) { levels.save($0, for: client) }
                                Button {} label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                            } else {
                                Button("Set Up…") {}.buttonStyle(.borderedProminent)
                            }
                        }
                    } label: {
                        Text(client)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
