import SwiftUI
import msgblastCore

/// Connection checks are deliberately fresh after a restart. Saved selections and
/// permission checkpoints survive, but a previous process's successful check is not proof
/// that the app is still available.
struct OnboardingConnectionsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var setup: OnboardingController
    @State private var checked: Set<WebProvider> = []
    @State private var skipped: Set<WebProvider> = []
    @State private var sessionRevision = 0

    private var appAccessReady: Bool { (setup.state.approvedPermissionSections ?? []).contains(.apps) }
    private var sessions: [WebAgentSession] { setup.pendingDesktopSessions }
    private var busy: Bool {
        model.busy || model.webBroadcastBusy || setup.checking || setup.permissionChecksBusy ||
            sessions.contains { $0.loading || $0.isSending }
    }
    private var canContinue: Bool {
        !busy && !sessions.isEmpty && sessions.allSatisfy {
            skipped.contains($0.provider) || (appAccessReady && checked.contains($0.provider) && setup.isReady($0))
        }
    }

    var body: some View {
        let _ = sessionRevision
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Connect your agents").font(.system(size: 28, weight: .bold))
                Text("Connect each app, or skip it for now. These checks don’t send messages.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("desktop-onboarding-connection-required")
                if model.demo {
                    Text("Demo connections are simulated. No app is contacted.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !appAccessReady {
                    HStack {
                        Text("App access needs attention. Review permissions or skip these apps.").font(.callout)
                        Button("Review permissions") { setup.reviewPermissions() }.buttonStyle(.link)
                    }
                }
            }.padding(28)
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(sessions, id: \.provider) { session in
                        OnboardingConnectionRow(session: session, busy: busy, accessReady: appAccessReady,
                                                checked: checked.contains(session.provider),
                                                skipped: skipped.contains(session.provider),
                                                onConnected: {
                            checked.insert(session.provider)
                            skipped.remove(session.provider)
                        }, onSkip: {
                            checked.remove(session.provider)
                            skipped.insert(session.provider)
                        }, onRetry: {
                            skipped.remove(session.provider)
                        }, onStateChange: { sessionRevision += 1 })
                    }
                }.padding(.horizontal, 28).padding(.bottom, 24)
            }
            Divider()
            HStack {
                Button("Back") { setup.back() }.disabled(busy)
                Spacer()
                Button("Continue") { setup.completeDesktopConnections(checked: checked, skipped: skipped) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(!canContinue)
            }.padding(24)
        }
        .task {
            for session in sessions { setup.prepareDesktopConnection(session) }
        }
    }
}

private struct OnboardingConnectionRow: View {
    @ObservedObject var session: WebAgentSession
    var busy: Bool
    var accessReady: Bool
    var checked: Bool
    var skipped: Bool
    var onConnected: () -> Void
    var onSkip: () -> Void
    var onRetry: () -> Void
    var onStateChange: () -> Void
    private var ready: Bool { accessReady && checked && session.isReadyForOnboarding }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                AgentAvatar(agent: AgentArtwork.agent(for: session), name: session.provider.name, size: 36)
                Text(session.provider.name).font(.headline)
                Spacer()
                if skipped {
                    Text("Skipped").font(.callout).foregroundStyle(.secondary)
                    Button("Connect instead", action: onRetry).disabled(busy)
                        .accessibilityLabel("Connect \(session.provider.name) instead")
                } else {
                    Label(ready ? "Ready" : "Not connected", systemImage: ready ? "checkmark.circle.fill" : "circle")
                        .font(.callout).foregroundStyle(ready ? .green : .secondary)
                    Button("Skip", action: onSkip).buttonStyle(.link).disabled(busy)
                        .accessibilityLabel("Skip \(session.provider.name)")
                }
            }
            if !skipped && accessReady {
                DesktopAppSetupView(session: session, busy: busy, compact: true,
                                    showConnectionConfirmation: ready, onConnected: onConnected)
            }
        }.padding(16)
            .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.10)))
            .onReceive(session.objectWillChange) { _ in onStateChange() }
    }
}
