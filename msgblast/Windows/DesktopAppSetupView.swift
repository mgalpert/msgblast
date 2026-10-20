import SwiftUI
import AppKit
import msgblastCore

struct DesktopAppSetupView: View {
    @ObservedObject var session: WebAgentSession
    var busy = false
    var showConnectionConfirmation = true
    var onConnected: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let app = session.provider.desktopApp {
                let installed = session.desktopInstallation.isInstalled
                Label(installed ? "\(app.name) is installed on this Mac" : "\(app.name) isn’t installed on this Mac",
                      systemImage: installed ? "checkmark.application" : "app.badge")
                    .font(.callout.weight(.medium)).accessibilityIdentifier("desktop-app-installation")
                if session.fixture {
                    Text("Simulated installation and connection · no app contacted")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if showConnectionConfirmation, let confirmation = session.desktopConnectionConfirmation {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(session.snapshot.messages.isEmpty ? "Ready for your first prompt" : "Ready to chat", systemImage: "checkmark.circle.fill")
                            .font(.callout.weight(.semibold)).foregroundStyle(.green)
                        Text(confirmation).font(.caption).foregroundStyle(.secondary)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.green.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityIdentifier("desktop-connection-confirmation")
                } else {
                    Text(!installed ? "Install \(app.name), then check again. You can connect it later, too." : app == .muse
                         ? "Open Muse and sign in. We’ll check its conversation and message field; your first prompt will start its own side chat."
                         : app == .wabi ? "Open Wabi and sign in. Your first prompt in each comparison starts a dedicated AI chat; follow-ups stay together."
                         : "Open the conversation you want to use in \(app.name). We’ll check it before you send a prompt.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Enable \(session.name)", isOn: Binding(get: { session.isEnabled }, set: { session.setEnabled($0) }))
                    .toggleStyle(.switch).disabled(busy || session.isSending || session.loading || (!installed && !session.isEnabled))
                    .accessibilityIdentifier("Enable \(session.name)")
                HStack {
                    if installed && !session.desktopInstallation.isRunning {
                        Button("Open \(app.name)") { Task { await session.openDesktopApp() } }
                            .disabled(busy || session.loading || session.isSending)
                    } else if installed {
                        Button(app == .muse ? "Check Muse connection" : "Check connection") {
                            Task {
                                await session.connectDesktopConversation()
                                if session.isReadyForOnboarding { onConnected() }
                            }
                        }.disabled(busy || session.loading || session.isSending || !session.isEnabled)
                    }
                    Button("Check installation") { session.refreshDesktopInstallation() }
                        .disabled(busy || session.loading || session.isSending)
                        .accessibilityIdentifier("check-desktop-installation")
                    if session.loading { ProgressView().controlSize(.small) }
                }
                if !session.desktopReady { Text(session.desktopStatus).font(.caption).foregroundStyle(.secondary) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
        .task { session.refreshDesktopInstallation() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            session.refreshDesktopInstallation()
        }
    }
}
