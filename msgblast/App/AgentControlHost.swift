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
            return AgentControlAgent(id: controlID(entry), name: session?.name ?? entry.name, kind: kind, visible: visible.contains(entry.id),
                                     selected: selected, busy: session.map { webAgents.isBusyForSelection($0) } ?? false)
        }
    }

    /// A featured Messages agent (Instinct, Fo, szn) is listed by its contact's `messages:` id, the id the send
    /// tools take, once it resolves to a saved contact. Until then it keeps its `featured:` id and can't be sent to.
    private func controlID(_ entry: AgentGridEntry) -> String {
        guard case .featuredMessages = entry.id, state.agents.contains(where: { $0.id == entry.agent.id }) else { return entry.id.id }
        return RemoteAgentIDs.messages(entry.agent.id)
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

    /// What the event feed compares each second. Only the most recent open comparisons are read.
    func controlSnapshot() -> AgentControlSnapshot {
        var snapshot = AgentControlSnapshot()
        let busy = webAgents.sessions.filter { webAgents.isBusyForSelection($0) }
        snapshot.busy = Set(busy.map(\.name))
        let recent = state.comparisons.filter { $0.endedAt == nil }.sorted { $0.created > $1.created }.prefix(AgentControlSnapshot.watchedComparisons)
        for comparison in recent {
            snapshot.created[comparison.id] = comparison.created
            for member in comparison.members {
                let key = AgentControlSnapshot.Key(comparisonID: comparison.id, agent: member.name)
                snapshot.replies[key] = transcript(comparison, member: member).filter { !$0.outgoing }.count
                snapshot.states[key] = member.submission.rawValue
            }
            for id in comparison.resolvedWebAgentIDs {
                guard let session = webAgents.sessions.first(where: { $0.id == id }) else { continue }
                let key = AgentControlSnapshot.Key(comparisonID: comparison.id, agent: session.name)
                snapshot.replies[key] = session.messagesForComparison(comparison.id).filter { $0.role != "user" }.count
                if busy.contains(where: { $0.id == id }) { snapshot.settling.insert(key) }
            }
        }
        return snapshot
    }
}

/// Asks the person, in msgblast, whether an outside agent may use it. `overTailscale` is the remote HTTP path.
/// Not modal: a modal loop blocks the main actor, so approved agents and quit wait on this one prompt.
@MainActor func approveOutsideAgent(_ client: String, overTailscale: Bool = false) async -> AgentControlAccess? {
    let alert = NSAlert()
    alert.messageText = "\(client) wants to use msgblast"
    let origin = overTailscale ? "It connects over your Tailscale network." : "It is an app on this Mac."
    alert.informativeText = """
    \(origin) Choose what it may do:
    • Read only: see your agents, comparisons and replies, including the text of messages. It can’t send anything.
    • Full access: everything, including sends to your AI agents and Messages contacts.
    You can change or remove this in Settings → Outside agents.
    """
    let levels = AgentControlAccess.allCases
    let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 220, height: 26), pullsDown: false)
    picker.addItems(withTitles: levels.map(\.label))
    alert.accessoryView = picker
    alert.addButton(withTitle: "Allow")
    alert.addButton(withTitle: "Don’t Allow")
    alert.layout()
    alert.window.level = .floating
    alert.window.center()
    alert.window.isReleasedWhenClosed = false
    return await withCheckedContinuation { continuation in
        OutsideAgentPrompt.begin(alert: alert, levels: levels, picker: picker, continuation: continuation)
        NSApp.activate(ignoringOtherApps: true)
        alert.window.makeKeyAndOrderFront(nil)
    }
}

/// One open approval. Kept alive until Allow, Don’t Allow, the window closing, or quit resumes it.
@MainActor private final class OutsideAgentPrompt: NSObject {
    private static var pending = Set<OutsideAgentPrompt>()
    private let alert: NSAlert
    private let levels: [AgentControlAccess]
    private let picker: NSPopUpButton
    private var continuation: CheckedContinuation<AgentControlAccess?, Never>?
    private var closing = false

    static func begin(alert: NSAlert, levels: [AgentControlAccess], picker: NSPopUpButton, continuation: CheckedContinuation<AgentControlAccess?, Never>) {
        let prompt = OutsideAgentPrompt(alert: alert, levels: levels, picker: picker, continuation: continuation)
        pending.insert(prompt)
        for (index, button) in alert.buttons.enumerated() {
            button.target = prompt
            button.action = #selector(pressed(_:))
            button.tag = index
        }
        let center = NotificationCenter.default
        center.addObserver(prompt, selector: #selector(dismiss(_:)), name: NSWindow.willCloseNotification, object: alert.window)
        center.addObserver(prompt, selector: #selector(dismiss(_:)), name: NSApplication.willTerminateNotification, object: nil)
    }

    private init(alert: NSAlert, levels: [AgentControlAccess], picker: NSPopUpButton, continuation: CheckedContinuation<AgentControlAccess?, Never>) {
        self.alert = alert
        self.levels = levels
        self.picker = picker
        self.continuation = continuation
        super.init()
    }

    @objc private func pressed(_ sender: NSButton) {
        let index = picker.indexOfSelectedItem
        finish(sender.tag == 0 && levels.indices.contains(index) ? levels[index] : nil)
    }

    @objc private func dismiss(_ notification: Notification) {
        if notification.name == NSWindow.willCloseNotification { closing = true }
        finish(nil)
    }

    private func finish(_ access: AgentControlAccess?) {
        guard let continuation else { return }
        self.continuation = nil
        NotificationCenter.default.removeObserver(self)
        Self.pending.remove(self)
        if !closing {
            closing = true
            alert.window.close()
        }
        continuation.resume(returning: access)
    }
}
