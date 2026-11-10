import AppKit
import msgblastCore

extension AppModel: AgentControlHost {
    func controlStatus() -> AgentControlStatus {
        let ready = onboarding.permissionReadiness
        return AgentControlStatus(
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            permissions: ["fullDiskAccess": ready.fullDiskAccess, "contacts": ready.contacts, "automation": ready.automation,
                          "deviceControl": ready.hostAccessibility, "screenRecording": ready.screenCapture],
            busyAgents: webAgents.sessions.filter { webAgents.isBusyForSelection($0) }.map(\.name))
    }

    func controlAgents() -> [AgentControlAgent] {
        let visible = Set(agentGridLayout.visibleIDs)
        return agentGridCatalog.map { entry in
            let session = webAgents.sessions.first { $0.id.gridID == entry.id }
            let kind: String
            switch entry.id {
            case .messages, .featuredMessages: kind = "messages"
            case .runtime: kind = "report"
            case .web, .webInstance:
                let provider = session?.provider
                kind = provider?.desktopApp != nil ? "app" : provider?.personalAgentProvider != nil ? "cli" : provider == .grokbot ? "bot" : "website"
            }
            let selected = session?.state.selected ?? state.selection.contains(entry.agent.id)
            return AgentControlAgent(id: entry.id.id, name: session?.name ?? entry.name, kind: kind, visible: visible.contains(entry.id),
                                     selected: selected, busy: session.map { webAgents.isBusyForSelection($0) } ?? false)
        }
    }

    func controlComparisons() -> [Comparison] { state.comparisons }

    func controlTranscript(_ comparison: Comparison) -> [AgentControlTurn] {
        let messages = comparison.members.flatMap { member in
            transcript(comparison, member: member).map { AgentControlTurn(agent: member.name, outgoing: $0.outgoing, text: $0.text, date: $0.date) }
        }
        let web = comparison.resolvedWebAgentIDs.flatMap { id -> [AgentControlTurn] in
            guard let session = webAgents.sessions.first(where: { $0.id == id }) else { return [] }
            return session.messagesForComparison(comparison.id).map { AgentControlTurn(agent: session.name, outgoing: $0.role == "user", text: $0.text, date: nil) }
        }
        return messages + web
    }
}

/// Asks the person, in msgblast, whether an outside agent may use it. `overTailscale` is the remote HTTP path.
@MainActor func approveOutsideAgent(_ client: String, overTailscale: Bool = false) async -> AgentControlAccess? {
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = "\(client) wants to use msgblast"
    alert.informativeText = overTailscale
        ? "It connects over your Tailscale network. Choose what it may do. You can change or remove this in Settings → Outside agents."
        : "It is an app on this Mac. Choose what it may do. You can change or remove this in Settings → Outside agents."
    let levels = AgentControlAccess.allCases
    let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 220, height: 26), pullsDown: false)
    picker.addItems(withTitles: levels.map(\.label))
    alert.accessoryView = picker
    alert.addButton(withTitle: "Allow")
    alert.addButton(withTitle: "Don’t Allow")
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    return levels[picker.indexOfSelectedItem]
}
