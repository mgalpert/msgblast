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
        ForEach(gate.approvals.keys.sorted(), id: \.self) { client in
            HStack {
                Picker(client, selection: Binding(get: { gate.approvals[client] ?? .readOnly }, set: { try? gate.set($0, for: client) })) {
                    ForEach(AgentControlAccess.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Button("Remove") { try? gate.set(nil, for: client) }
            }
        }
    }
}
