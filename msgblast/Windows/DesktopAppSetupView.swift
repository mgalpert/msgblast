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
                    Text(instructions(for: app, installed: installed))
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
                if app == .gemini, installed, session.isEnabled {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Mode", selection: Binding(get: { session.geminiPreferences.mode }, set: { mode in
                            var choice = session.geminiPreferences
                            choice.mode = mode; choice.model = nil; choice.thinking = nil
                            Task { await session.configureGemini(choice) }
                        })) {
                            ForEach(GeminiMode.allCases, id: \.self) { Text($0.name).tag($0) }
                        }.pickerStyle(.segmented).disabled(session.geminiModeLocked)
                            .accessibilityIdentifier("gemini-mode-picker")
                        if session.geminiModeLocked { Text("Start a new comparison to switch between Chat and Task.").font(.caption).foregroundStyle(.secondary) }
                        if !session.geminiOptions.models.isEmpty {
                            Picker("Model", selection: Binding(get: { session.geminiPreferences.model.flatMap { session.geminiOptions.models.contains($0) ? $0 : nil } ?? "" }, set: { model in
                                guard !model.isEmpty else { return }
                                var choice = session.geminiPreferences
                                choice.model = model; choice.thinking = nil
                                Task { await session.configureGemini(choice) }
                            })) {
                                Text("Choose a model…").tag("").disabled(true)
                                ForEach(session.geminiOptions.models, id: \.self) { Text($0.replacingOccurrences(of: ", ", with: " · ")).tag($0) }
                            }.accessibilityIdentifier("gemini-model-picker")
                        }
                        if !session.geminiOptions.thinkingLevels.isEmpty {
                            Picker("Thinking level", selection: Binding(get: { session.geminiPreferences.thinking.flatMap { session.geminiOptions.thinkingLevels.contains($0) ? $0 : nil } ?? "" }, set: { thinking in
                                guard !thinking.isEmpty else { return }
                                var choice = session.geminiPreferences; choice.thinking = thinking
                                Task { await session.configureGemini(choice) }
                            })) {
                                Text("Choose a thinking level…").tag("").disabled(true)
                                ForEach(session.geminiOptions.thinkingLevels, id: \.self) { Text($0).tag($0) } }
                                .accessibilityIdentifier("gemini-thinking-picker")
                        }
                        if session.geminiOptions.thinkingLevels.isEmpty, session.geminiPreferences.thinking != nil {
                            Button("Use Gemini’s default thinking") {
                                var choice = session.geminiPreferences; choice.thinking = nil
                                Task { await session.configureGemini(choice) }
                            }
                        }
                        Button("Refresh Gemini options") { Task { await session.configureGemini(session.geminiPreferences) } }
                            .accessibilityIdentifier("gemini-refresh-options")
                    }.disabled(busy || session.loading || session.isSending || !session.desktopInstallation.isRunning)
                }
                HStack {
                    if !installed { Link("Get \(app.name)", destination: session.provider.homeURL) }
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
                                if app == .gemini, session.isReadyForOnboarding { await session.configureGemini(session.geminiPreferences) }
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

    private func instructions(for app: DesktopAppProvider, installed: Bool) -> String {
        guard installed else { return "Install \(app.name), then check again. You can connect it later, too." }
        switch app {
        case .muse: return "Open Muse and sign in. We’ll check its conversation and message field; your first prompt will start its own side chat."
        case .wabi: return "Open Wabi and sign in. Your first prompt in each comparison starts a dedicated AI chat; follow-ups stay together."
        case .chatgpt, .claude: return "Sign in to \(app.name) once. msgblast opens the app when a conversation starts and keeps each comparison in its own chat."
        case .dots: return "Sign in to ChatGPT to connect your dot. msgblast opens the native app for you."
        case .gemini: return "Open Gemini and sign in. Choose Chat or Task here; each comparison gets its own conversation."
        case .grokBot: return "Choose your bot below. msgblast will open it for you whenever you send a message."
        }
    }

    private func loadBots() async {
        await session.refreshGrokBots()
        if session.isReadyForOnboarding { onConnected() }
    }
}
