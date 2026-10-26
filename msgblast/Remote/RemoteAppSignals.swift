import Foundation
import msgblastCore
import msgblastRemoteProtocol

/// Reads the signals remote control needs from AppModel. Every probe here is one the
/// app already runs without prompting: permission preflights, a one-byte history
/// read, Automation with `ask: false`, and `refreshDesktopInstallation`.
extension AppModel {
    func remoteAvailabilityInputs(settings: RemoteSettings) -> MacAvailabilityInputs {
        var inputs = MacAvailabilityInputs()
        let messages = onboarding.messagesPermissions, apps = onboarding.appPermissions
        inputs.fullDiskAccess = Self.remoteState(messages.history)
        inputs.contacts = demo ? (contactsAvailable ? .allowed : .notRequested) : Self.remoteState(messages.contacts)
        inputs.automation = Self.remoteState(messages.sending)
        inputs.accessibility = Self.remoteState(apps.hostAccessibility)
        inputs.screenRecording = Self.remoteState(apps.windowCapture)
        // Before the first permission refresh the driver check has not run.
        inputs.driverInstalled = apps.hostAccessibility == .checking ? nil : apps.installed
        inputs.databaseAvailable = databaseAvailable
        inputs.databaseStatus = databaseStatus
        inputs.messagesBusy = busy
        inputs.messagesSendsAllowed = settings.allowMessagesSends
        inputs.visibleGridIDs = agentGridLayout.visibleIDs
        let gridIDs = messageGridIDs
        inputs.messagesAgents = state.agents.map { agent in
            MessagesAgentSignal(agentID: agent.id, gridID: gridIDs[agent.id] ?? .messages(agent.id), name: agent.name, routable: route(agent) != nil,
                                routeStatus: messageConnectionStatus(agent), selected: state.selection.contains(agent.id))
        }
        return inputs
    }

    /// One pass of the side-effect-free probes. `slow` adds CLI account status for CLIs
    /// that are already connected (the same `login status` check their pane runs).
    func remoteAvailabilityProbe(slow: Bool) async {
        await onboarding.messagesPermissions.refresh(model: self)
        await onboarding.appPermissions.refresh(demo: demo)
        for session in webAgents.sessions where session.provider.desktopApp != nil { session.refreshDesktopInstallation() }
        if slow {
            for session in webAgents.sessions where session.provider.personalAgentProvider != nil && session.connected && !session.isSending {
                await session.refresh()
            }
        }
    }

    var remoteGridAgentIDs: [String] {
        agentGridLayout.visibleIDs.compactMap { id in
            if let session = webAgents.session(for: id) { return session.id.id }
            return messageAgent(for: id).map { RemoteAgentIDs.messages($0.id) }
        }
    }

    func remoteMacStatus(settings: RemoteSettings, power: MacPowerState, keepAwake: RemoteKeepAwake) -> MacStatus {
        let variant: MacVariant = demo ? .demo : Bundle.main.bundleIdentifier == "com.msgblast.mac" ? .production : .development
        return MacStatus(macName: Host.current().localizedName ?? "Mac", variant: variant, locked: power.locked, awake: power.awake,
                         databaseAvailable: databaseAvailable, databaseStatus: databaseStatus, messagesBusy: busy, broadcastBusy: webBroadcastBusy,
                         sendingAgentIDs: webAgents.sessions.filter(\.isSending).map(\.id.id), keepAwakeEnabled: settings.keepAwake,
                         keepAwakeHeld: keepAwake.held, messagesSendsAllowed: settings.allowMessagesSends, observedAt: Date())
    }

    func remoteProjectionInput(settings: RemoteSettings, power: MacPowerState, keepAwake: RemoteKeepAwake, agents: [AgentAvailability]) -> RemoteProjectionInput {
        var input = RemoteProjectionInput(macStatus: remoteMacStatus(settings: settings, power: power, keepAwake: keepAwake), gridAgentIDs: remoteGridAgentIDs,
                                          agents: agents, comparisons: state.comparisons)
        for comparison in state.comparisons {
            var transcripts: [UUID: [Message]] = [:]
            for member in comparison.members { transcripts[member.id] = transcript(comparison, member: member) }
            input.messagesTranscripts[comparison.id] = transcripts
            if let summary = comparison.summary {
                input.reports[comparison.id] = RemoteReport(provider: summary.provider, overview: summary.report?.overview ?? summary.text, comparison: summary.report?.comparison,
                                                            uncertainties: summary.report?.uncertainties ?? [], running: personalAgent.running.contains(comparison.id),
                                                            error: personalAgent.errors[comparison.id])
            } else if personalAgent.running.contains(comparison.id) || personalAgent.errors[comparison.id] != nil {
                input.reports[comparison.id] = RemoteReport(provider: nil, overview: nil, comparison: nil, uncertainties: [],
                                                            running: personalAgent.running.contains(comparison.id), error: personalAgent.errors[comparison.id])
            }
        }
        input.gatherWebState(from: webAgents.sessions)
        return input
    }

    private static func remoteState(_ status: AppPermissionStatus) -> RemotePermissionState {
        switch status {
        case .allowed: .allowed
        case .notRequested: .notRequested
        case .denied, .restricted: .denied
        case .needsMessages: .needsMessages
        case .checking, .notConnected, .unavailable: .unknown
        }
    }
    private static func remoteState(_ status: CuaPermissionStatus) -> RemotePermissionState {
        switch status {
        case .allowed: .allowed
        case .off: .denied
        case .checking, .unknown, .notInstalled: .unknown
        }
    }
}
