import AppKit
import SwiftUI
import msgblastCore

/// Settings → Outside agents: turn the local socket on, and change or remove each approved agent.
struct OutsideAgentsSettingsView: View {
    @ObservedObject var listener: AgentControlListener
    @ObservedObject var gate: AgentControlGate

    var body: some View {
        Toggle("Let agents on this Mac use msgblast", isOn: Binding(get: { listener.enabled }, set: { listener.enabled = $0 }))
        Text("Agents such as Claude Code and Codex connect through the msgblast command. Each one asks you once, here in msgblast, and gets the level you choose.")
            .font(.caption).foregroundStyle(.secondary)
        if let error = listener.error { Text(error).font(.caption).foregroundStyle(.red) }
        if listener.enabled {
            LabeledContent("Claude Code") { Button("Copy setup command") { copy(Self.setup("claude")) } }
            LabeledContent("Codex") { Button("Copy setup command") { copy(Self.setup("codex")) } }
            LabeledContent("Terminal") {
                Button("Copy msgblast command path") { copy(AgentControlCommand.executable) }
            }
            TailnetControls(tailnet: listener.tailnet)
        }
        ForEach(gate.approvals.keys.sorted(), id: \.self) { client in
            HStack {
                Picker(client, selection: Binding(get: { gate.approvals[client] ?? .readOnly }, set: { try? gate.set($0, for: client) })) {
                    ForEach(AgentControlAccess.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Button("Remove") {
                    try? gate.set(nil, for: client)
                    listener.tailnet.revoke(client)
                }
            }
        }
    }

    /// The command that adds msgblast as an MCP server to `claude` or `codex`. Each asks for approval on first use.
    static func setup(_ tool: String, executable: String = AgentControlCommand.executable) -> String {
        "\(tool) mcp add msgblast -- '\(executable.replacingOccurrences(of: "'", with: "'\\''"))' mcp"
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

}

/// Shown under Terminal while Outside agents is on. The listener stays quiet until this toggle is on.
private struct TailnetControls: View {
    @ObservedObject var tailnet: AgentControlTailnetListener
    @State private var confirmingNewKey = false

    var body: some View {
        Group {
            Toggle("Let Grok Bot use msgblast over Tailscale", isOn: Binding(get: { tailnet.enabled }, set: { tailnet.enabled = $0 }))
                .disabled(tailnet.loadFailed)
            ForEach(tailnet.readiness, id: \.self) { line in
                Text(line).font(.caption).foregroundStyle(.secondary)
            }
            if tailnet.enabled, let url = tailnet.serverURL {
                Text(url)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Copy URL") { copy(url) }
                if tailnet.showsAddressFallback {
                    Text("Tailscale's name for this Mac wasn't found, so this is its 100.x address.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if tailnet.enabled, let header = tailnet.authorizationHeader {
                Text(header)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Copy header") { copy(header) }
                if let path = tailnet.pathURL {
                    Button("Copy link with key (if headers aren't available)") { copy(path) }
                        .controlSize(.small)
                }
                Button("New key") { confirmingNewKey = true }
                if let setup = tailnet.setupText {
                    Button("Copy Grok Bot setup") { copy(setup) }
                }
            } else if tailnet.enabled {
                Text("Make a new key to see it again").font(.caption).foregroundStyle(.secondary)
                Button("New key") { tailnet.rotateToken() }
            }
            Text("1. In Grok Bot: Connect apps → Your plugins → Tailscale → Authenticate.\n2. In Grok Bot: Add a custom connector → Remote HTTPS, Server URL = the URL above, header = the header above.\n3. Ask Grok Bot to call msgblast_status; approve it here.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = tailnet.error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .onAppear { tailnet.refreshStatus() }
        .alert("Make a new key?", isPresented: $confirmingNewKey) {
            Button("Cancel", role: .cancel) {}
            Button("New key") { tailnet.rotateToken() }
        } message: {
            Text("The current key stops working. Give Grok Bot the new one.")
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
