import AppKit
import SwiftUI
import XCTest
@testable import msgblastCore

/// Settings → Outside agents adds an agent's row the moment the approval alert saves its level.
/// These host rows laid out like that page in a real window and check that building or redrawing
/// a row never saves a level by itself.
@MainActor final class AgentAccessMenuTests: XCTestCase {
    func testMenuRowKeepsANewFullAccessApproval() {
        let levels = Levels()
        let writes = approve(levels, in: Rows(levels: levels, control: .menu))
        XCTAssertEqual(writes, [], "a row saved a level on its own")
        XCTAssertEqual(levels.approvals["Codex"], .full)
    }

    func testMenuSavesOnlyAChangedLevel() {
        XCTAssertEqual(AgentAccessMenu.choice(.full, picked: true, current: .readOnly), .full)
        XCTAssertEqual(AgentAccessMenu.choice(.readOnly, picked: true, current: .full), .readOnly)
        XCTAssertNil(AgentAccessMenu.choice(.full, picked: true, current: .full))
        XCTAssertNil(AgentAccessMenu.choice(.full, picked: false, current: .full))
    }

    /// Diagnostic for the Codex report: the Picker row main shipped, under the same steps.
    func testProbePickerRowLikeMain() {
        let levels = Levels()
        let writes = approve(levels, in: Rows(levels: levels, control: .picker))
        print("ACCESS-PROBE picker-main writes=\(writes) final=\(String(describing: levels.approvals["Codex"]))")
        XCTAssertEqual(writes, [], "PROBE picker-main wrote \(writes)")
    }

    /// Diagnostic: the same, with an approved agent already listed below where Codex's row goes.
    func testProbePickerRowLikeMainAboveAnotherAgent() {
        let levels = Levels()
        let writes = approve(levels, in: Rows(levels: levels, control: .picker), existing: ["Evidence Agent": .full])
        print("ACCESS-PROBE picker-main-above writes=\(writes) final=\(String(describing: levels.approvals["Codex"]))")
        XCTAssertEqual(writes, [], "PROBE picker-main-above wrote \(writes)")
    }

    /// Diagnostic: #124's older layout, where Full access was seen to stick.
    func testProbePickerRowLike124() {
        let levels = Levels()
        let writes = approve(levels, in: OldRows(levels: levels))
        print("ACCESS-PROBE picker-124 writes=\(writes) final=\(String(describing: levels.approvals["Codex"]))")
        XCTAssertEqual(writes, [], "PROBE picker-124 wrote \(writes)")
    }

    /// Shows the page, then saves Full access for Codex while an alert-like window is key, closes that
    /// window so the page becomes key again, and redraws a few times. Returns every level the rows saved.
    private func approve(_ levels: Levels, in view: some View, existing: [String: AgentControlAccess] = [:]) -> [String] {
        levels.approvals = existing
        let page = window(NSHostingView(rootView: view), width: 680, height: 460)
        defer { page.close() }
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

/// Settings → Outside agents → Agents as main lays it out: Grok Bot first, then each agent with its level and Remove.
private struct Rows: View {
    enum Control { case menu, picker }
    @ObservedObject var levels: Levels
    let control: Control
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
                                switch control {
                                case .menu:
                                    AgentAccessMenu(level) { levels.save($0, for: client) }
                                case .picker:
                                    Picker(client, selection: Binding(get: { levels.approvals[client] ?? .readOnly }, set: { levels.save($0, for: client) })) {
                                        ForEach(AgentControlAccess.allCases, id: \.self) { Text($0.label).tag($0) }
                                    }
                                    .labelsHidden().fixedSize()
                                }
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

/// #124's layout: one Picker and Remove per approved agent, in the page's single section.
private struct OldRows: View {
    @ObservedObject var levels: Levels

    var body: some View {
        let _ = levels.redraws
        Form {
            Section {
                Toggle("Allow agents on this Mac", isOn: .constant(true))
                ForEach(levels.approvals.keys.sorted(), id: \.self) { client in
                    HStack {
                        Picker(client, selection: Binding(get: { levels.approvals[client] ?? .readOnly }, set: { levels.save($0, for: client) })) {
                            ForEach(AgentControlAccess.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        Button("Remove") {}
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
