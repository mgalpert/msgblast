import SwiftUI
import AppKit
import msgblastCore

struct AppAgentsSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var web: WebAgents
    @ObservedObject var permissions: CuaPermissionsController

    private var busy: Bool { model.busy || model.webBroadcastBusy || web.sessions.contains { $0.isSending || $0.loading } }
    private var accessReady: Bool { model.onboarding.permissionReadiness.appsReady }

    var body: some View {
        Text("Connection checks don’t send messages.").font(.caption).foregroundStyle(.secondary)
        if !accessReady {
            Text("Enable app access in Permissions to connect.").font(.caption).foregroundStyle(.secondary)
        }
        ForEach(web.sessions.filter { $0.provider.desktopApp != nil }, id: \.id) { session in
            AppAgentSettingsRow(model: model, session: session, busy: busy, accessReady: accessReady)
        }
        .task { model.onboarding.refreshDesktopInstallations() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.onboarding.refreshDesktopInstallations()
        }
    }
}

private struct AppAgentSettingsRow: View {
    @ObservedObject var model: AppModel
    @ObservedObject var session: WebAgentSession
    var busy: Bool
    var accessReady: Bool
    @State private var showingSetup = false

    var body: some View {
        HStack(spacing: 10) {
            AgentAvatar(agent: AgentArtwork.agent(for: session), name: session.provider.name, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.provider.name).fontWeight(.medium)
                if !session.provider.isAvailableInBuild {
                    Text("Unavailable in this build").font(.caption).foregroundStyle(.secondary)
                } else if session.desktopInstallation.isInstalled {
                    Text("Installed").font(.caption).foregroundStyle(.secondary)
                } else {
                    Link("Install", destination: session.provider.homeURL).font(.caption)
                        .accessibilityLabel("Install \(session.provider.name)")
                }
            }
            Spacer()
            Button("Set up") { showingSetup = true }
                .accessibilityLabel("Set up \(session.provider.name)")
                .accessibilityIdentifier("setup-app-\(session.provider.rawValue)")
                .disabled(busy || !accessReady || !session.isEnabled)
            Toggle("", isOn: Binding(get: { session.isEnabled }, set: { enabled in
                session.setEnabled(enabled)
                if session.isEnabled {
                    var grid = model.agentGridLayout
                    grid.add(session.id.gridID)
                    _ = model.setAgentGrid(grid)
                }
            }))
            .toggleStyle(PermissionSwitchStyle()).frame(width: 40)
            .accessibilityLabel("Enable \(session.provider.name)")
            .accessibilityIdentifier("enable-app-\(session.provider.rawValue)")
            .disabled(busy || !session.provider.isAvailableInBuild || (!session.desktopInstallation.isInstalled && !session.isEnabled))
        }
        .sheet(isPresented: $showingSetup) {
            AppAgentSetupSheet(session: session, busy: busy)
        }
    }
}

private struct AppAgentSetupSheet: View {
    @ObservedObject var session: WebAgentSession
    var busy: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var checked = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                AgentAvatar(agent: AgentArtwork.agent(for: session), name: session.provider.name, size: 36)
                Text("Set up \(session.provider.name)").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if session.fixture {
                Text("Demo connections are simulated. No app is contacted.").font(.caption).foregroundStyle(.secondary)
            }
            DesktopAppSetupView(session: session, busy: busy, compact: true,
                                showConnectionConfirmation: checked && session.isReadyForOnboarding,
                                onConnected: { checked = true })
        }.padding(24).frame(width: 500)
    }
}
