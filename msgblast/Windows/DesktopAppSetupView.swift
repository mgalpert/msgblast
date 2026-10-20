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
                         : "Choose your bot below. msgblast will open it for you whenever you send a message.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Enable \(session.name)", isOn: Binding(get: { session.isEnabled }, set: { session.setEnabled($0) }))
                    .toggleStyle(.switch).disabled(busy || session.isSending || session.loading || (!installed && !session.isEnabled))
                    .accessibilityIdentifier("Enable \(session.name)")
                if app == .grokBot, installed, session.desktopInstallation.isRunning {
                    Picker("Bot", selection: Binding<String?>(get: {
                        session.state.desktopConversation.map(\.name).flatMap { session.grokBotNames.contains($0) ? $0 : nil }
                    }, set: { name in
                        guard let name else { return }
                        Task {
                            await session.connectDesktopConversation(botName: name)
                            if session.isReadyForOnboarding { onConnected() }
                        }
                    })) {
                        Text("Choose a bot…").tag(String?.none)
                        ForEach(session.grokBotNames, id: \.self) { name in Text(name).tag(Optional(name)) }
                    }.pickerStyle(.menu).accessibilityIdentifier("grok-bot-picker")
                        .disabled(busy || session.loading || session.isSending || !session.isEnabled || session.grokBotNames.isEmpty)
                }
                HStack {
                    if installed && !session.desktopInstallation.isRunning {
                        Button("Open \(app.name)") { Task {
                            await session.openDesktopApp()
                            if app == .grokBot { await loadBots() }
                        } }
                            .disabled(busy || session.loading || session.isSending)
                    } else if installed, app != .grokBot {
                        Button(app == .muse ? "Check Muse connection" : "Check connection") {
                            Task {
                                await session.connectDesktopConversation()
                                if session.isReadyForOnboarding { onConnected() }
                            }
                        }.disabled(busy || session.loading || session.isSending || !session.isEnabled)
                    }
                    Button(app == .grokBot ? "Refresh bots" : "Check installation") {
                        if app == .grokBot { Task { await loadBots() } }
                        else { session.refreshDesktopInstallation() }
                    }
                        .disabled(busy || session.loading || session.isSending)
                        .accessibilityIdentifier("check-desktop-installation")
                    if session.loading { ProgressView().controlSize(.small) }
                }
                if !session.desktopReady { Text(session.desktopStatus).font(.caption).foregroundStyle(.secondary) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
        .task {
            session.refreshDesktopInstallation()
            if session.provider == .grokBotApp { await loadBots() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            session.refreshDesktopInstallation()
            if session.provider == .grokBotApp { Task { await loadBots() } }
        }
    }

    private func loadBots() async {
        await session.refreshGrokBots()
        if session.isReadyForOnboarding { onConnected() }
    }
}
