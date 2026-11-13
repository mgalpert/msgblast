import AppKit
import SwiftUI
import msgblastCore

/// Settings → Outside agents, laid out like a System Settings pane: a switch for this Mac, a switch for
/// Tailscale, and one list of agents. Setup steps and keys live in sheets, explanations in tooltips.
struct OutsideAgentsSettingsView: View {
    @ObservedObject var listener: AgentControlListener
    @ObservedObject var gate: AgentControlGate
    @ObservedObject var activity: AgentControlActivity

    var body: some View {
        Section("This Mac") {
            Toggle("Allow agents on this Mac", isOn: Binding(get: { listener.enabled }, set: { listener.enabled = $0 }))
                .help("Agents such as Claude Code and Codex connect through the msgblast command. Each asks once and gets the access you choose.")
                .accessibilityIdentifier("outside-agents-enabled")
            if listener.enabled {
                LabeledContent("Set up an agent") { setupMenu }
                AgentSendsSettings(activity: activity)
            }
            if let error = listener.error ?? gate.saveError { ErrorRow(text: error) }
        }
        TailnetSection(tailnet: listener.tailnet, localOn: listener.enabled) { listener.enabled = true }
        AgentsSection(gate: gate, tailnet: listener.tailnet, tailnetOn: listener.enabled && listener.tailnet.enabled)
    }

    private var setupMenu: some View {
        Menu("Copy Setup") {
            Button("Claude Code") { Pasteboard.copy(Self.setup("claude")) }
            Button("Codex") { Pasteboard.copy(Self.setup("codex")) }
            Button("Cursor or Gemini CLI") { Pasteboard.copy(AgentControlCLI.mcpConfig(executable: AgentControlCommand.executable)) }
            Button("Other MCP App") { Pasteboard.copy(Self.mcpCommand()) }
            Divider()
            Button("msgblast Command Path") { Pasteboard.copy(AgentControlCommand.executable) }
        }
        .fixedSize()
        .help("Copies the command or config for that agent. Run it, or paste it into the agent's MCP settings.")
    }

    /// The command that adds msgblast as an MCP server to `claude` or `codex`. Each asks for approval on first use.
    static func setup(_ tool: String, executable: String = AgentControlCommand.executable) -> String {
        "\(tool) mcp add msgblast -- \(mcpCommand(executable: executable))"
    }

    /// The stdio MCP server command, for any MCP client on this Mac.
    static func mcpCommand(executable: String = AgentControlCommand.executable) -> String {
        "'\(executable.replacingOccurrences(of: "'", with: "'\\''"))' mcp"
    }
}

/// The Tailscale switch, then either the server URL or the one thing that needs fixing. Always shown:
/// turning it on turns on outside agents too, which it needs.
private struct TailnetSection: View {
    @ObservedObject var tailnet: AgentControlTailnetListener
    let localOn: Bool
    let turnOnLocal: () -> Void

    private var on: Bool { localOn && tailnet.enabled }
    /// Readiness problems about this Mac. Whether Grok Bot has called shows on its own row instead.
    private var problem: String? {
        tailnet.readiness.first { !$0.hasPrefix("\u{2713}") && !$0.contains("Grok Bot hasn't called") }
    }

    var body: some View {
        Section("Tailscale") {
            Toggle("Allow agents on other devices", isOn: Binding(get: { on }, set: { value in
                if value, !localOn { turnOnLocal() }
                tailnet.enabled = value
            }))
            .help("Agents such as Grok Bot, or Claude Code on another computer, reach msgblast over your private tailnet. Each gets its own key.")
            .disabled(tailnet.loadFailed)
            .accessibilityIdentifier("outside-agents-tailnet-enabled")
            if on, let problem { problemRow(problem) }
            if on, let url = tailnet.serverURL {
                LabeledContent("Server URL") {
                    ValueWithCopy(value: url) { Pasteboard.copy(url) }.accessibilityIdentifier("outside-agents-mcp-url")
                }
                .help(tailnet.showsAddressFallback ? "Tailscale's name for this Mac wasn't found, so this is its 100.x address." : "")
            }
            if let error = tailnet.error { ErrorRow(text: error) }
        }
        .onAppear { tailnet.refreshStatus() }
    }

    private func problemRow(_ line: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(String(line.drop { $0 != " " }.dropFirst()), systemImage: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .textSelection(.enabled)
            HStack {
                if let command = tailnet.serveCommand {
                    Button("Copy Command") { Pasteboard.copy(command) }.accessibilityIdentifier("outside-agents-serve-command")
                }
                Button("Check Again") { tailnet.refreshStatus() }
            }
            .controlSize(.small)
        }
    }
}

/// Every agent msgblast knows: approved, refused, or holding a Tailscale key. One row each.
private struct AgentsSection: View {
    @ObservedObject var gate: AgentControlGate
    @ObservedObject var tailnet: AgentControlTailnetListener
    let tailnetOn: Bool
    @State private var sheet: SheetClient?
    @State private var adding = false
    @State private var newName = ""
    @State private var addError: String?

    private var names: [String] {
        let all = Set(gate.approvals.keys).union(gate.refused).union(tailnetOn ? tailnet.clients : [])
        return all.sorted { ($0 == AgentControlTailnet.grokBotClient ? 0 : 1, $0) < ($1 == AgentControlTailnet.grokBotClient ? 0 : 1, $1) }
    }

    var body: some View {
        if !names.isEmpty || tailnetOn {
            Section("Agents") {
                ForEach(names, id: \.self) { row($0) }
                if tailnetOn { addRow }
            }
            .sheet(item: $sheet) { item in
                if item.id == AgentControlTailnet.grokBotClient {
                    GrokBotSetupSheet(tailnet: tailnet)
                } else {
                    KeySheet(tailnet: tailnet, client: item.id)
                }
            }
        }
    }

    private func row(_ client: String) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                if gate.refused.contains(client) {
                    Button("Ask Again") { gate.forgetRefusal(client) }
                } else if gate.approvals[client] != nil {
                    Picker(client, selection: Binding(get: { gate.approvals[client] ?? .readOnly }, set: { gate.change($0, for: client) })) {
                        ForEach(AgentControlAccess.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    .help("Read only can see agents, comparisons and replies. Full access can also send.")
                } else if client == AgentControlTailnet.grokBotClient {
                    Button("Set Up…") { sheet = SheetClient(id: client) }.buttonStyle(.borderedProminent)
                }
                if tailnetOn, tailnet.clients.contains(client), gate.approvals[client] != nil || client != AgentControlTailnet.grokBotClient {
                    Button { sheet = SheetClient(id: client) } label: { Image(systemName: "info.circle") }
                        .buttonStyle(.borderless).help("Setup and key").accessibilityLabel("Details")
                }
                Button { gate.change(nil, for: client); tailnet.revoke(client) } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless).help("Remove \(client)").accessibilityLabel("Remove")
            }
        } label: {
            Text(client)
            if gate.refused.contains(client) { Text("Refused until msgblast quits") }
        }
        .accessibilityIdentifier(client == AgentControlTailnet.grokBotClient ? "outside-agents-grok-bot" : "")
    }

    private var addRow: some View {
        Button { adding = true } label: { Label("Add Agent…", systemImage: "plus") }
            .buttonStyle(.borderless)
            .popover(isPresented: $adding, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Name", text: $newName, prompt: Text("Claude Code on my laptop")).frame(width: 240).onSubmit(add)
                    if let addError { Text(addError).font(.caption).foregroundStyle(.red) }
                    HStack { Spacer(); Button("Add", action: add).keyboardShortcut(.defaultAction).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty) }
                }
                .padding()
            }
            .help("Adds an agent on another device with its own key.")
    }

    private func add() {
        addError = tailnet.add(newName)
        guard addError == nil else { return }
        sheet = SheetClient(id: AgentControlTailnet.remoteClientName(newName) ?? newName)
        newName = ""
        adding = false
    }
}

private struct SheetClient: Identifiable { let id: String }

/// Grok Bot's "Add a custom connector" form, field for field, so each value can be copied across.
private struct GrokBotSetupSheet: View {
    @ObservedObject var tailnet: AgentControlTailnetListener
    @Environment(\.dismiss) private var dismiss
    @State private var confirming = false
    private let client = AgentControlTailnet.grokBotClient

    var body: some View {
        let url = tailnet.serverURL.flatMap { $0.hasPrefix("https://") ? $0 : nil }
        Form {
            Section("1. In Grok Bot, connect Tailscale") {
                LabeledContent("Connect apps → Your plugins → Tailscale") {
                    Text(tailnet.grokBotOnTailnet ? "Connected" : "Waiting").foregroundStyle(.secondary)
                }
            }
            Section("2. Add a custom connector") {
                FormField(label: "Name", value: "msgblast")
                FormField(label: "Type", value: "Remote HTTPS", copyable: false)
                FormField(label: "Server URL", value: url ?? "Needs HTTPS first", copyable: url != nil)
                FormField(label: "Header", value: "Authorization")
                if let value = tailnet.authorizationValue(for: client) {
                    FormField(label: "Value", value: "Bearer ••••••••", secret: value)
                } else {
                    FormField(label: "Value", value: "Make a new key to copy it", copyable: false)
                }
                FormField(label: "Client ID", value: "Leave empty", copyable: false)
            }
            Section("3. Click Add plugin, then approve msgblast here") {}
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .toolbar { SheetToolbar(hasKey: tailnet.authorizationValue(for: client) != nil, confirming: $confirming, extra: GrokBotApp.url) { dismiss() } }
        .newKeyConfirmation($confirming, name: "Grok Bot") { tailnet.rotateToken(client) }
    }
}

/// Copy actions for a tailnet agent's key, available only right after the key is made.
private struct KeySheet: View {
    @ObservedObject var tailnet: AgentControlTailnetListener
    let client: String
    @Environment(\.dismiss) private var dismiss
    @State private var confirming = false

    var body: some View {
        Form {
            Section(client) {
                if let header = tailnet.authorizationHeader(for: client) {
                    LabeledContent("Header") { Button("Copy") { Pasteboard.copySecret(header) } }
                    if let path = tailnet.pathURL(for: client) {
                        LabeledContent("Link with key") { Button("Copy") { Pasteboard.copySecret(path) } }
                            .help("For clients that can't send headers")
                    }
                    if let setup = tailnet.setupText(for: client) {
                        LabeledContent("URL and header") { Button("Copy") { Pasteboard.copySecret(setup) } }
                    }
                } else {
                    Text("A key can be copied only right after it's made.").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .toolbar { SheetToolbar(hasKey: tailnet.authorizationHeader(for: client) != nil, confirming: $confirming, extra: nil) { dismiss() } }
        .newKeyConfirmation($confirming, name: client) { tailnet.rotateToken(client) }
    }
}

/// New Key, an optional Open Grok Bot, and Done.
private struct SheetToolbar: ToolbarContent {
    let hasKey: Bool
    @Binding var confirming: Bool
    let extra: URL?
    let done: () -> Void

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .cancellationAction) {
            if let extra { Button("Open Grok Bot") { NSWorkspace.shared.open(extra) } }
            Button(hasKey ? "New Key…" : "Make Key") { confirming = true }
        }
        ToolbarItem(placement: .confirmationAction) { Button("Done", action: done) }
    }
}

private extension View {
    /// Asks before replacing a key, since the old one stops working.
    func newKeyConfirmation(_ shown: Binding<Bool>, name: String, make: @escaping () -> Void) -> some View {
        confirmationDialog("Make a new key for \(name)?", isPresented: shown) {
            Button("New Key", action: make)
        } message: {
            Text("The current key stops working. Copied keys clear from the clipboard after 2 minutes.")
        }
    }
}

/// One field of Grok Bot's connector form. `secret` is copied in place of the shown value, as a key.
private struct FormField: View {
    let label: String
    let value: String
    var copyable = true
    var secret: String?

    var body: some View {
        LabeledContent(label) {
            if copyable {
                ValueWithCopy(value: value) { if let secret { Pasteboard.copySecret(secret) } else { Pasteboard.copy(value) } }
            } else {
                Text(value).foregroundStyle(.secondary)
            }
        }
    }
}

/// A value in secondary monospace with a copy icon after it.
private struct ValueWithCopy: View {
    let value: String
    let copy: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(value).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            Button(action: copy) { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless).help("Copy").accessibilityLabel("Copy")
        }
    }
}

private struct ErrorRow: View {
    let text: String
    var body: some View { Label(text, systemImage: "exclamationmark.octagon.fill").foregroundStyle(.red) }
}

private enum Pasteboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Marked concealed so clipboard history apps skip it, and cleared after 2 minutes
    /// unless something else was copied since.
    @MainActor static func copySecret(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
        board.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        let copied = board.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) {
            if NSPasteboard.general.changeCount == copied { NSPasteboard.general.clearContents() }
        }
    }
}

/// The Grok Bot desktop app, when it is installed. It has no link to its connector screen, so this only opens it.
private enum GrokBotApp {
    static var url: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anysphere.sand") }
}
