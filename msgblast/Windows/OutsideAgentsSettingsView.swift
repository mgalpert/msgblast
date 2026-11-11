import AppKit
import SwiftUI
import msgblastCore

/// Settings → Outside agents: turn the local socket on, and change or remove each approved agent.
struct OutsideAgentsSettingsView: View {
    @ObservedObject var listener: AgentControlListener
    @ObservedObject var gate: AgentControlGate

    var body: some View {
        Toggle("Let agents on this Mac use msgblast", isOn: Binding(get: { listener.enabled }, set: { listener.enabled = $0 }))
            .accessibilityIdentifier("outside-agents-enabled")
        Text("Agents such as Claude Code and Codex connect through the msgblast command. Each one asks you once, here in msgblast, and gets the level you choose.")
            .font(.caption).foregroundStyle(.secondary)
        if let error = listener.error { Text(error).font(.caption).foregroundStyle(.red) }
        if let error = gate.saveError { Text(error).font(.caption).foregroundStyle(.red) }
        if listener.enabled {
            LabeledContent("Claude Code") { Button("Copy setup command") { copy(Self.setup("claude")) } }
            LabeledContent("Codex") { Button("Copy setup command") { copy(Self.setup("codex")) } }
            LabeledContent("Terminal") {
                Button("Copy msgblast command path") { copy(AgentControlCommand.executable) }
            }
            LabeledContent("MCP server on this Mac") {
                VStack(alignment: .trailing, spacing: 4) {
                    Text("Command: msgblast mcp (stdio, no URL)")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Button("Copy MCP command") { copy(Self.mcpCommand()) }
                }
            }
            Text("Other MCP apps on this Mac, such as Cursor, add msgblast as a command server with this command. Agents on other devices use the MCP server URL below.")
                .font(.caption).foregroundStyle(.secondary)
            TailnetControls(tailnet: listener.tailnet)
        }
        ForEach(gate.approvals.keys.sorted(), id: \.self) { client in
            HStack {
                Picker(client, selection: Binding(get: { gate.approvals[client] ?? .readOnly }, set: { gate.change($0, for: client) })) {
                    ForEach(AgentControlAccess.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Button("Remove") {
                    gate.change(nil, for: client)
                    listener.tailnet.revoke(client)
                }
            }
        }
        ForEach(gate.refused.sorted(), id: \.self) { client in
            HStack {
                Text(client)
                Spacer()
                Text("Refused until msgblast quits").font(.caption).foregroundStyle(.secondary)
                Button("Ask Again") { gate.forgetRefusal(client) }
            }
        }
    }

    /// The command that adds msgblast as an MCP server to `claude` or `codex`. Each asks for approval on first use.
    static func setup(_ tool: String, executable: String = AgentControlCommand.executable) -> String {
        "\(tool) mcp add msgblast -- \(mcpCommand(executable: executable))"
    }

    /// The stdio MCP server command, for any MCP client on this Mac.
    static func mcpCommand(executable: String = AgentControlCommand.executable) -> String {
        "'\(executable.replacingOccurrences(of: "'", with: "'\\''"))' mcp"
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

}

/// Shown under Terminal while Outside agents is on. The listener stays quiet until this toggle is on.
/// Any MCP client on the tailnet can connect; each agent gets its own key and its own approval.
private struct TailnetControls: View {
    @ObservedObject var tailnet: AgentControlTailnetListener
    @State private var confirmingNewKey: String?
    @State private var newName = ""
    @State private var addError: String?

    var body: some View {
        Group {
            Toggle("Let agents on other devices use msgblast over Tailscale", isOn: Binding(get: { tailnet.enabled }, set: { tailnet.enabled = $0 }))
                .disabled(tailnet.loadFailed)
                .accessibilityIdentifier("outside-agents-tailnet-enabled")
            if !tailnet.enabled {
                Text("Turn this on to get an MCP server URL that agents on other devices, such as Grok Bot or Claude Code on another computer, can reach over your tailnet.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(tailnet.readiness, id: \.self) { line in
                Text(line).font(.caption).foregroundStyle(.secondary)
            }
            urlRow
            if tailnet.enabled { agentRows }
            if let error = tailnet.error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .onAppear { tailnet.refreshStatus() }
        .alert("Make a new key?", isPresented: Binding(get: { confirmingNewKey != nil }, set: { if !$0 { confirmingNewKey = nil } })) {
            Button("Cancel", role: .cancel) { confirmingNewKey = nil }
            Button("New key") {
                if let client = confirmingNewKey { tailnet.rotateToken(client) }
                confirmingNewKey = nil
            }
        } message: {
            Text("\(confirmingNewKey ?? "This agent")'s current key stops working. Give it the new one.")
        }
    }

    @ViewBuilder private var urlRow: some View {
        if tailnet.enabled, let url = tailnet.serverURL {
            LabeledContent("MCP server URL") {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(url)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("outside-agents-mcp-url")
                    Button("Copy URL") { copy(url) }
                }
            }
            if tailnet.showsAddressFallback {
                Text("Tailscale's name for this Mac wasn't found, so this is its 100.x address.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var agentRows: some View {
        ForEach(tailnet.clients, id: \.self) { client in
            clientRow(client)
        }
        HStack {
            TextField("Agent name, such as Claude Code on my laptop", text: $newName)
                .onSubmit(add)
            Button("Add agent", action: add)
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        if let addError { Text(addError).font(.caption).foregroundStyle(.red) }
        Text("Copies with a key are cleared from the clipboard after 2 minutes. A key is shown once; choose New key to see another.")
            .font(.caption).foregroundStyle(.secondary)
        Text("Any MCP client on your tailnet: use the MCP server URL above and that agent's header, then approve it here on its first call.\nGrok Bot: Connect apps → Your plugins → Tailscale → Authenticate, then Add a custom connector → Remote HTTPS with the URL and header.")
            .font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder private func clientRow(_ client: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(client).font(.callout.weight(.medium))
                Spacer()
                Button("New key") {
                    if tailnet.authorizationHeader(for: client) == nil { tailnet.rotateToken(client) } else { confirmingNewKey = client }
                }
                Button("Remove") { tailnet.remove(client) }
            }
            if let header = tailnet.authorizationHeader(for: client) {
                Text(header)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Button("Copy header") { copySecret(header) }
                    if let path = tailnet.pathURL(for: client) {
                        Button("Copy link with key") { copySecret(path) }
                            .help("For clients that can't send headers")
                    }
                    if let setup = tailnet.setupText(for: client) {
                        Button("Copy setup") { copySecret(setup) }
                    }
                }
                .controlSize(.small)
            } else {
                Text("Make a new key to see it again").font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func add() {
        addError = tailnet.add(newName)
        if addError == nil { newName = "" }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Marked concealed so clipboard history apps skip it, and cleared after 2 minutes
    /// unless something else was copied since.
    private func copySecret(_ text: String) {
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
