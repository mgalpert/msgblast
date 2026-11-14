import AppKit
import SwiftUI
import msgblastCore

/// Settings → Outside agents, laid out like a System Settings pane: a switch for this Mac, a switch for
/// Tailscale, and one list of agents. Setup steps and keys open in small windows, explanations in tooltips.
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
                InstallRow(tool: .claudeCode)
                InstallRow(tool: .codex)
                LabeledContent("Other agents") { setupMenu }
                AgentSendsSettings(activity: activity)
            }
            if let error = listener.error ?? gate.saveError { ErrorRow(text: error) }
        }
        TailnetSection(tailnet: listener.tailnet, localOn: listener.enabled) { listener.enabled = true }
        AgentsSection(gate: gate, tailnet: listener.tailnet, tailnetOn: listener.enabled && listener.tailnet.enabled) {
            if !listener.enabled { listener.enabled = true }
            if !listener.tailnet.enabled { listener.tailnet.enabled = true }
        }
    }

    private var setupMenu: some View {
        Menu("Copy Setup") {
            Button("Claude Code") { Pasteboard.copy(Self.setup("claude")) }
            Button("Codex") { Pasteboard.copy(Self.setup("codex")) }
            Divider()
            Button("Cursor or Gemini CLI") { Pasteboard.copy(AgentControlCLI.mcpConfig(executable: AgentControlCommand.executable)) }
            Button("Other MCP App") { Pasteboard.copy(Self.mcpCommand()) }
            Divider()
            Button("msgblast Command Path") { Pasteboard.copy(AgentControlCommand.executable) }
        }
        .fixedSize()
        .help("Copies the command or config for that agent. Run it, or paste it into the agent's MCP settings.")
    }

    /// Replaces any msgblast entry in `claude` or `codex` with this build's, for every project (Claude Code's
    /// user scope; Codex's config is global already). Each agent still asks for approval on first use.
    static func setup(_ tool: String, executable: String = AgentControlCommand.executable) -> String {
        let scope = tool == "claude" ? " --scope user" : ""
        return "\(tool) mcp remove\(scope) msgblast >/dev/null 2>&1; \(tool) mcp add\(scope) msgblast -- \(mcpCommand(executable: executable))"
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

/// Adds msgblast to Claude Code or Codex by running its own `mcp add` in a login shell, so the person's PATH finds it.
private struct InstallRow: View {
    enum Tool: String { case claudeCode = "claude", codex
        var label: String { self == .claudeCode ? "Claude Code" : "Codex" }
    }
    let tool: Tool
    @State private var state: String?
    @State private var running = false

    var body: some View {
        LabeledContent {
            Button(running ? "Adding…" : state == "added" ? "Added" : "Add") { Task { await install() } }
                .disabled(running)
        } label: {
            Text(tool.label)
            if let state, state != "added" { Text(state).foregroundStyle(.red) }
        }
        .help("Runs \(tool.rawValue) mcp add for you. Restart \(tool.label) afterwards.")
    }

    private func install() async {
        running = true
        let command = OutsideAgentsSettingsView.setup(tool.rawValue)
        let status = await Task.detached { () -> Int32 in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return -1 }
            // A prompt or a slow login shell must not leave the row on Adding… forever.
            DispatchQueue.global().asyncAfter(deadline: .now() + 30) { if process.isRunning { process.terminate() } }
            process.waitUntilExit()
            return process.terminationStatus
        }.value
        running = false
        switch status {
        case 0: state = "added"
        case 127: state = "\(tool.label) isn't installed, or isn't on your PATH."
        default: state = "Couldn't add msgblast. Choose Copy Setup and run it in Terminal to see why."
        }
    }
}

/// Every agent msgblast knows: approved, refused, or holding a Tailscale key. One row each.
private struct AgentsSection: View {
    @ObservedObject var gate: AgentControlGate
    @ObservedObject var tailnet: AgentControlTailnetListener
    let tailnetOn: Bool
    /// Turns on outside agents and Tailscale, which Grok Bot needs.
    let turnOnTailnet: () -> Void
    @State private var adding = false
    @State private var newKind = AgentControlTailnet.Kind.claudeCode
    @State private var newName = ""
    @State private var addError: String?

    private var names: [String] {
        let all = Set(gate.approvals.keys).union(gate.refused).union(tailnet.clients).union([AgentControlTailnet.grokBotClient])
        return all.sorted { ($0 == AgentControlTailnet.grokBotClient ? 0 : 1, $0) < ($1 == AgentControlTailnet.grokBotClient ? 0 : 1, $1) }
    }

    var body: some View {
        Section("Agents") {
            ForEach(names, id: \.self) { row($0) }
            addRow
        }
    }

    private func show(_ client: String) {
        if client == AgentControlTailnet.grokBotClient {
            SetupWindow.show("Set Up Grok Bot", GrokBotSetupSheet(tailnet: tailnet, gate: gate))
        } else {
            SetupWindow.show(client, KeySheet(tailnet: tailnet, client: client))
        }
    }

    /// Opening Grok Bot's setup means the person wants Grok Bot: turn on what it needs, and make a key
    /// to copy unless Grok Bot is already approved, since a new key would break a working connector.
    private func setUpGrokBot() {
        let client = AgentControlTailnet.grokBotClient
        if !tailnetOn { turnOnTailnet() }
        if gate.approvals[client] == nil, tailnet.authorizationValue(for: client) == nil { tailnet.rotateToken(client) }
        show(client)
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
                    Button("Set Up…", action: setUpGrokBot).buttonStyle(.borderedProminent)
                }
                if client == AgentControlTailnet.grokBotClient, gate.approvals[client] != nil {
                    Button(action: setUpGrokBot) { Image(systemName: "info.circle") }
                        .buttonStyle(.borderless).help("Setup and key").accessibilityLabel("Details")
                } else if client != AgentControlTailnet.grokBotClient, tailnet.clients.contains(client) {
                    Button { show(client) } label: { Image(systemName: "info.circle") }
                        .buttonStyle(.borderless).help("Setup and key").accessibilityLabel("Details")
                }
                if tailnet.clients.contains(client) || gate.approvals[client] != nil || gate.refused.contains(client) {
                    Button { gate.change(nil, for: client); tailnet.revoke(client) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).help("Remove \(client)").accessibilityLabel("Remove")
                }
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
                Form {
                    Picker("Agent", selection: $newKind) {
                        ForEach(AgentControlTailnet.Kind.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    if newKind == .other {
                        TextField("Name", text: $newName, prompt: Text("My agent")).onSubmit(add)
                    }
                    if let addError { Text(addError).foregroundStyle(.red) }
                }
                .formStyle(.grouped)
                .frame(width: 300)
                .fixedSize(horizontal: false, vertical: true)
                HStack { Spacer(); Button("Add", action: add).keyboardShortcut(.defaultAction).disabled(newKind == .other && newName.trimmingCharacters(in: .whitespaces).isEmpty) }
                    .padding([.horizontal, .bottom])
            }
            .help("Adds an agent on another device, with its own key, over Tailscale.")
    }

    /// Known agents get their own name, numbered when one already exists, so usage counts by kind.
    private func add() {
        if newKind == .grokBot {
            adding = false
            return setUpGrokBot()
        }
        if !tailnetOn { turnOnTailnet() }
        let base = newKind == .other ? newName : newKind.label
        var typed = base
        var number = 2
        while let name = AgentControlTailnet.remoteClientName(typed), tailnet.clients.contains(name) || gate.approvals[name] != nil {
            typed = "\(base) \(number)"
            number += 1
        }
        addError = tailnet.add(typed)
        guard addError == nil else { return }
        show(AgentControlTailnet.remoteClientName(typed) ?? typed)
        newName = ""
        adding = false
    }
}

/// Setup and key details open in their own small window, not a sheet: a sheet on the Settings
/// window stops msgblast from quitting until it is closed. One at a time.
@MainActor private enum SetupWindow {
    private static var window: NSWindow?

    static func show(_ title: String, _ content: some View) {
        window?.close()
        let next = NSWindow(contentViewController: NSHostingController(rootView: content))
        next.title = title
        next.styleMask = [.titled, .closable]
        next.isReleasedWhenClosed = false
        next.center()
        window = next
        next.makeKeyAndOrderFront(nil)
    }

    static func close() { window?.close() }
}

/// Grok Bot's "Add a custom connector" form, field for field, so each value can be copied across.
private struct GrokBotSetupSheet: View {
    @ObservedObject var tailnet: AgentControlTailnetListener
    @ObservedObject var gate: AgentControlGate
    @State private var confirming = false
    private let client = AgentControlTailnet.grokBotClient

    var body: some View {
        let url = tailnet.serverURL.flatMap { $0.hasPrefix("https://") ? $0 : nil }
        SheetLayout(hasKey: tailnet.authorizationValue(for: client) != nil, confirming: $confirming, extra: GrokBotApp.url, width: 500) {
            Section("1. In Grok Bot, connect Tailscale") {
                LabeledContent("Connect apps → Your plugins → Tailscale") {
                    Text(tailnet.grokBotOnTailnet ? "Connected" : "Waiting").foregroundStyle(.secondary)
                }
            }
            Section {
                FormField(label: "Name", value: "msgblast")
                FormField(label: "Type", value: "Remote HTTPS", copyable: false)
                FormField(label: "Server URL", value: url ?? (tailnet.enabled ? "Needs HTTPS first" : "Turn on Tailscale first"), copyable: url != nil)
                FormField(label: "Key", value: "Authorization")
                if let value = tailnet.authorizationValue(for: client) {
                    FormField(label: "Value", value: "Bearer ••••••••", secret: value)
                } else {
                    FormField(label: "Value", value: "Make a new key to copy it", copyable: false)
                }
                FormField(label: "Client ID", value: "Leave empty", copyable: false)
            } header: {
                Text("2. Add a custom connector")
                HStack(spacing: 4) {
                    Text("In Grok Bot, click")
                    ConnectAppsIcon()
                    Text("then scroll down to Add a custom connector.")
                }
                .font(.caption).foregroundStyle(.secondary)
            } footer: {
                Text("Copy all the fields into Grok Bot, then click Add plugin.")
            }
            Section("3. Send this to Grok Bot, then click Allow in the alert") {
                FormField(label: "Message", value: GrokBotApp.firstMessage)
                if tailnet.wrongKey {
                    Label("An agent sent an old key. If it's Grok Bot, copy the Value again.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else if gate.approvals[client] != nil {
                    Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Text("Waiting for Grok Bot").foregroundStyle(.secondary)
                }
            }
        }
        .newKeyConfirmation($confirming, name: "Grok Bot") { tailnet.rotateToken(client) }
    }
}

/// Grok Bot's Connect apps button: three rounded squares and a plus, so people can spot it in Grok Bot.
private struct ConnectAppsIcon: View {
    var body: some View {
        Grid(horizontalSpacing: 1.5, verticalSpacing: 1.5) {
            GridRow { tile; tile }
            GridRow { tile; Image(systemName: "plus").font(.system(size: 6, weight: .bold)).frame(width: 5, height: 5) }
        }
        .padding(3)
        .overlay(Circle().stroke(.secondary.opacity(0.4)))
        .accessibilityLabel("Connect apps")
    }

    private var tile: some View { RoundedRectangle(cornerRadius: 1.5).stroke(lineWidth: 1).frame(width: 5, height: 5) }
}

/// Copy actions for a tailnet agent's key, available only right after the key is made.
private struct KeySheet: View {
    @ObservedObject var tailnet: AgentControlTailnetListener
    let client: String
    @State private var confirming = false

    var body: some View {
        SheetLayout(hasKey: tailnet.authorizationHeader(for: client) != nil, confirming: $confirming, extra: nil, width: 420) {
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
        .newKeyConfirmation($confirming, name: client) { tailnet.rotateToken(client) }
    }
}

/// A setup window's form with New Key, an optional Open Grok Bot, and Done along the bottom. Esc and Return close it.
private struct SheetLayout<Content: View>: View {
    let hasKey: Bool
    @Binding var confirming: Bool
    let extra: URL?
    let width: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            Form { content }.formStyle(.grouped).fixedSize(horizontal: false, vertical: true)
            HStack {
                if let extra { Button("Open Grok Bot") { NSWorkspace.shared.open(extra) } }
                Button(hasKey ? "New Key…" : "Make Key") { confirming = true }
                Spacer()
                Button("Done") { SetupWindow.close() }.keyboardShortcut(.defaultAction)
                // Esc in a plain window needs a cancel button; this one is invisible.
                Button("Close") { SetupWindow.close() }.keyboardShortcut(.cancelAction).hidden().frame(width: 0)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: width)
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
    /// A first chat message that makes Grok Bot call msgblast, so the approval alert appears.
    static let firstMessage = "Use msgblast to check its status and list my agents."
    static var url: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anysphere.sand") }
}
