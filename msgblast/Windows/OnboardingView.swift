import SwiftUI
import AppKit
import msgblastCore

struct OnboardingView: View {
    private static let browserIcons: [String: NSImage] = {
        var icons: [String: NSImage] = [:]
        for (source, identifier) in [("chrome", "com.google.Chrome"), ("safari", "com.apple.Safari")] {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
                icons[source] = NSWorkspace.shared.icon(forFile: url.path)
            }
        }
        return icons
    }()
    @ObservedObject var model: AppModel
    @ObservedObject private var setup: OnboardingController
    @State private var previousTelemetryScreen: TelemetryProperties.Screen?

    init(model: AppModel) {
        self.model = model
        setup = model.onboarding
    }

    var body: some View {
        VStack(spacing: 0) {
            OnboardingBreadcrumbs(activeStep: setup.state.stage == .feedback ? 2 : 1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28).padding(.top, 28)
            if setup.state.needsPermissionSetup {
                OnboardingPermissionsView(model: model, setup: setup)
            } else if setup.state.messagesDiscoveryReviewed == false {
                OnboardingDiscoveredMessagesView(model: model, setup: setup)
            } else if setup.state.stage == .choosing { ScrollView { chooser } }
            else if setup.state.stage == .importing { browserImport }
            else if setup.state.stage == .feedback { OnboardingFeedbackView() }
            else if let step = setup.state.currentStep {
                switch step {
                case .agent(let provider):
                    if provider.desktopApp != nil {
                        OnboardingConnectionsView(model: model, setup: setup)
                    } else {
                        OnboardingProviderView(model: model, setup: setup, session: setup.session(for: provider))
                            .id(provider)
                    }
                case .messages:
                    OnboardingDiscoveredMessagesView(model: model, setup: setup)
                case .runtime(let runtime):
                    OnboardingRuntimeView(model: model, setup: setup, runtime: runtime).id(runtime)
                }
            }
            if let error = setup.error ?? model.error {
                Text(error).font(.callout).foregroundStyle(.orange).padding(.horizontal, 28)
            }
            if !setup.state.needsPermissionSetup && setup.state.messagesDiscoveryReviewed != false && !showingDesktopConnections && (setup.state.stage != .connecting || setup.state.currentStep != .messages) {
                Divider()
                HStack {
                    if setup.state.stage == .choosing {
                        Button("Back") { setup.reviewPermissions() }
                        Spacer()
                        Button("Continue setup") { setup.begin() }
                            .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                            .disabled(setup.permissionChecksBusy || setup.state.selected.isEmpty || setup.state.selected.contains { !choiceAvailable($0) })
                    } else {
                        Button("Back") { setup.back() }
                        Spacer()
                        if setup.state.stage == .feedback {
                            if setup.checking { ProgressView("Checking connections…").controlSize(.small) }
                            Button("Start chatting") { Task { await setup.finish() } }
                                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                                .disabled(setup.checking)
                        } else {
                            Button("Skip for now") { setup.skip() }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                    }
                }.padding(24).disabled(model.busy || (setup.state.stage == .importing && setup.checking))
            }
        }
        .frame(maxWidth: 840, maxHeight: .infinity)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: 740, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            setup.refreshDesktopInstallations()
            await setup.refreshPermissions()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            setup.refreshDesktopInstallations()
            Task { await setup.refreshPermissions() }
        }
        .onChange(of: telemetryScreenKey, initial: true) { _, _ in
            var properties = TelemetryProperties()
            properties.screen = telemetryScreen
            properties.previousScreen = previousTelemetryScreen
            if telemetryScreen == .providerConnection, case .agent(let provider) = setup.state.currentStep { properties.provider = provider.rawValue }
            if telemetryScreen == .runtimeSetup, case .runtime(let runtime) = setup.state.currentStep { properties.provider = runtime.rawValue }
            model.recordTelemetry(.onboardingScreenViewed, properties: properties)
            previousTelemetryScreen = telemetryScreen
        }
    }

    private var showingDesktopConnections: Bool {
        guard setup.state.stage == .connecting, case .agent(let provider) = setup.state.currentStep else { return false }
        return provider.desktopApp != nil
    }

    private var telemetryScreen: TelemetryProperties.Screen {
        if setup.state.needsPermissionSetup { return .permissions }
        if setup.state.messagesDiscoveryReviewed == false { return .messages }
        switch setup.state.stage {
        case .choosing: return .agents
        case .importing: return .browserImport
        case .feedback: return .feedback
        default:
            if case .runtime = setup.state.currentStep { return .runtimeSetup }
            if case .messages = setup.state.currentStep { return .messages }
            return .providerConnection
        }
    }
    private var telemetryScreenKey: String {
        let step: String
        switch setup.state.currentStep {
        case .agent(let provider) where telemetryScreen == .providerConnection: step = provider.rawValue
        case .runtime(let runtime) where telemetryScreen == .runtimeSetup: step = runtime.rawValue
        default: step = ""
        }
        return telemetryScreen.rawValue + ":" + step
    }

    private var browserImport: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Use your existing logins").font(.system(size: 28, weight: .bold))
                Text("Connect the accounts you're already signed into in your browser.")
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Text("Selected agents").foregroundStyle(.secondary)
                ForEach(WebProvider.allCases.filter { setup.state.pendingWebProviders.contains($0) }) { provider in
                    Text(provider.name).font(.callout)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.primary.opacity(0.06), in: Capsule())
                }
            }.padding(.bottom, 10)
            ForEach(BrowserLoginSource.allCases) { source in
                Button { setup.chooseBrowser(source) } label: {
                    HStack(spacing: 18) {
                        browserIcon(source).frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Import from \(source.name)").font(.title3.weight(.semibold)).foregroundStyle(.primary)
                            Text(source == .chrome ? "Choose a profile to connect your accounts." : "Connect with the accounts you use in Safari.")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.primary.opacity(0.015), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.14)))
                        .contentShape(RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(.plain).accessibilityLabel("Import from \(source.name)")
                    .disabled(setup.checking)
            }
            if setup.checking { ProgressView("Importing browser login…").controlSize(.small) }
            if model.demo {
                Label("Demo browser import · accounts and cookies are simulated", systemImage: "testtube.2")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }.padding(28)
        .sheet(isPresented: Binding(get: { !setup.browserProfiles.isEmpty }, set: { if !$0 { setup.cancelBrowserProfileSelection() } })) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Choose a \(setup.browserSource?.name ?? "browser") profile").font(.title2.bold())
                ForEach(setup.browserProfiles) { profile in
                    Button { setup.importBrowserProfile(profile) } label: {
                        HStack {
                            Text(profile.name).foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }.padding(14).frame(maxWidth: .infinity)
                            .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain).accessibilityLabel("Import \(profile.name)")
                }
                Button("Cancel") { setup.cancelBrowserProfileSelection() }.keyboardShortcut(.cancelAction)
            }.padding(24).frame(width: 420)
        }
    }

    private func browserIcon(_ source: BrowserLoginSource) -> some View {
        return Group {
            if let icon = Self.browserIcons[source.rawValue] {
                Image(nsImage: icon).resizable().scaledToFit()
            } else {
                Image(systemName: source == .safari ? "safari" : "globe").resizable().scaledToFit().padding(5).foregroundStyle(.blue)
            }
        }
    }

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Choose your agents").font(.system(size: 28, weight: .bold))
            Text("Add the agents you want in msgblast. You can change these later.")
                .foregroundStyle(.secondary)
            Text("Messaging agents").font(.headline)
            if !(setup.state.approvedPermissionSections ?? []).contains(.messaging) {
                permissionNote("Enable Messaging access to add Messages agents.")
            }
            choiceGrid(OnboardingChoice.allCases.filter(\.isMessages))
            Text("Mac apps").font(.headline)
            if !(setup.state.approvedPermissionSections ?? []).contains(.apps) {
                permissionNote("Enable App access to connect installed Mac apps.")
            }
            choiceGrid(OnboardingChoice.allCases.filter { $0.provider?.desktopApp != nil })
            Text("Websites").font(.headline)
            choiceGrid(OnboardingChoice.allCases.filter { OnboardingConnector.apps.includes($0) && $0.provider?.desktopApp == nil })
            Text("CLIs").font(.headline)
            choiceGrid(OnboardingChoice.allCases.filter { OnboardingConnector.clis.includes($0) })
            if model.onboardingPreview {
                Label("Demo onboarding · accounts and conversations are simulated", systemImage: "testtube.2")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(28).frame(maxHeight: .infinity, alignment: .top)
    }

    private func permissionNote(_ text: String) -> some View {
        HStack {
            Text(text).font(.callout).foregroundStyle(.secondary)
            Button("Review permissions") { setup.reviewPermissions() }.buttonStyle(.link)
        }
    }

    private func choiceAvailable(_ choice: OnboardingChoice) -> Bool {
        if choice.isMessages { return (setup.state.approvedPermissionSections ?? []).contains(.messaging) }
        if let provider = choice.provider, provider.desktopApp != nil {
            return (setup.state.approvedPermissionSections ?? []).contains(.apps) && setup.desktopInstallations[provider]?.isInstalled == true
        }
        return true
    }

    private func choiceGrid(_ choices: [OnboardingChoice]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
            ForEach(choices) { choice in choiceButton(choice) }
        }
    }

    private func choiceButton(_ choice: OnboardingChoice) -> some View {
        let selected = setup.state.selected.contains(choice)
        let selectionStatus = selected ? "Selected" : "Not selected"
        let desktop = choice.provider.flatMap { $0.desktopApp == nil ? nil : $0 }
        let installed = desktop.map { setup.desktopInstallations[$0]?.isInstalled == true } ?? true
        let available = choiceAvailable(choice)
        return Button { setup.edit { $0.toggle(choice) } } label: {
            HStack(spacing: 14) {
                if let provider = choice.provider {
                    AgentAvatar(agent: AgentArtwork.agent(for: setup.session(for: provider)), name: choice.name, size: 44)
                } else if let runtime = choice.runtime {
                    AgentAvatar(agent: Agent(name: choice.name, handles: [], avatar: AgentArtwork.runtimeAvatar(for: runtime)), name: choice.name, size: 44)
                } else if choice == .otherMessages {
                    Image(systemName: "message.fill").font(.system(size: 26)).foregroundStyle(.green)
                        .frame(width: 44, height: 44)
                } else {
                    AgentAvatar(agent: Agent(name: choice.name, handles: [], avatar: AgentArtwork.messageAvatar(for: choice)), name: choice.name, size: 44)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(choice == .otherMessages ? "Another Messages agent" : choice.name)
                        .font(.system(size: 14, weight: .medium)).foregroundStyle(.primary).lineLimit(2)
                    if let desktop {
                        Text(setup.desktopInstallations[desktop] == nil ? "Checking this Mac…" : installed ? "Installed on this Mac" : "Not installed")
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("desktop-installation-\(desktop.rawValue)")
                    }
                }
                Spacer(minLength: 6)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22)).foregroundStyle(selected ? Color.blue : .secondary)
            }
            .padding(12).frame(maxWidth: .infinity, minHeight: 74, maxHeight: 74, alignment: .leading)
            .background(selected ? Color.blue.opacity(0.12) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Color.blue : Color.primary.opacity(0.14), lineWidth: selected ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).accessibilityLabel("Choose \(choice.name)")
            .accessibilityValue(!installed ? "Not installed" : !available ? "Permission required. \(selectionStatus)" : desktop != nil ? "Installed on this Mac. \(selectionStatus)" : selectionStatus)
            .disabled(!available && !selected)
    }

}

private struct OnboardingFeedbackView: View {
    private static let screenshot: NSImage? = {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        return bundle.url(forResource: "feedback-menu", withExtension: "png", subdirectory: "Onboarding")
            .flatMap(NSImage.init(contentsOf:))
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Help shape msgblast").font(.system(size: 28, weight: .bold))
                Text("msgblast is open source. Share your feedback or build the feature you want to use.")
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 16) {
                    Label("Share feedback", systemImage: "bubble.left.and.bubble.right").font(.title2.bold())
                    Text("Tell us what works, what could be better, or what you’d like to see next.")
                        .foregroundStyle(.secondary)
                    if let screenshot = Self.screenshot {
                        Image(nsImage: screenshot).resizable().scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .accessibilityLabel("Help menu with Share Feedback highlighted")
                    }
                    Text("Help → Share Feedback…").font(.callout.weight(.medium))
                }.frame(maxWidth: .infinity, alignment: .leading)
                Divider()
                VStack(alignment: .leading, spacing: 16) {
                    Label("Build a new feature", systemImage: "hammer").font(.title2.bold())
                    Text("Make msgblast your own. Build a feature yourself or with a coding agent, then share it with the community.")
                        .foregroundStyle(.secondary)
                    Text("Get a ready-to-copy prompt with the source repository and instructions to get started.")
                        .foregroundStyle(.secondary)
                    Button("Build a New Feature…") { BuildFeatureWindowController.show() }
                        .buttonStyle(.bordered)
                    Text("Help → Build a New Feature…").font(.callout.weight(.medium))
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 680).padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct OnboardingProviderView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var setup: OnboardingController
    @ObservedObject var session: WebAgentSession
    @ObservedObject private var personalAgent: PersonalAgentController
    private var ready: Bool { setup.isReady(session) }

    init(model: AppModel, setup: OnboardingController, session: WebAgentSession) {
        self.model = model
        self.setup = setup
        self.session = session
        personalAgent = model.personalAgent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                AgentAvatar(agent: AgentArtwork.agent(for: session), name: session.provider.name, size: 48)
                Text("Let’s connect \(session.provider.name)").font(.title.bold())
            }
            if session.provider == .grokbot {
                ScrollView { GrokBotSetupView(session: session, busy: model.busy, selectAfterConnecting: false).padding(2) }.scrollIndicators(.hidden)
            } else if let provider = session.provider.personalAgentProvider {
                cliSetup(provider)
                Spacer()
            } else {
                if session.provider == .hark {
                    Text("Sign in to Hark here. Use its own composer to chat; shared sending is not supported yet.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if session.provider.sharesOneConversation {
                    Text("rabbit OS3 uses one conversation for your account. Each comparison continues that conversation and can use its earlier context.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let notice = setup.browserImportNotice {
                    Text(notice).font(.callout).foregroundStyle(.secondary)
                }
                ServiceLoginPage(session: session)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.12)))
            }
            HStack(spacing: 12) {
                if setup.checking || session.loading || session.configuringGrokBot {
                    ProgressView().controlSize(.small)
                    Text(session.grokBotConnectionActivity?.title ?? "Checking connection…")
                        .font(.callout).foregroundStyle(.secondary)
                } else if ready {
                    Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Spacer()
                Button("Continue") { setup.complete(session) }
                    .buttonStyle(.borderedProminent).disabled(!ready || setup.checking)
            }
        }.padding(28)
        .task {
            await setup.refresh(session)
        }
        .onChange(of: setup.isReady(session)) { _, _ in
            setup.advanceIfReady(session)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await setup.refresh(session) }
        }
    }

    private func cliSetup(_ provider: PersonalAgentProvider) -> some View {
        let installed = personalAgent.installed.contains { $0.provider == provider }
        return VStack(alignment: .leading, spacing: 18) {
            if session.fixture { Label("Demo account · no provider requests", systemImage: "testtube.2").font(.caption).foregroundStyle(.secondary) }
            if !installed {
                Label("\(session.provider.name) isn’t installed yet", systemImage: "arrow.down.circle")
                Link("Install \(session.provider.name)", destination: URL(string: provider == .codex ? "https://developers.openai.com/codex/cli" : "https://code.claude.com/docs/en/setup")!)
            } else if provider == .claude && setup.compatibility[session.provider] == false {
                Label("Update Claude Code to continue", systemImage: "arrow.clockwise.circle")
                Text(PersonalAgentError.conversationVersionRequired.localizedDescription).font(.callout).foregroundStyle(.secondary)
                Link("Claude Code setup guide", destination: URL(string: "https://code.claude.com/docs/en/setup")!)
            } else {
                Text(session.accountStatus.label).font(.headline)
                if !setup.isReady(session) {
                    Button("Sign in to \(session.provider.name)") { personalAgent.signIn(provider) }
                        .buttonStyle(.borderedProminent).disabled(session.fixture)
                }
            }
            if let error = personalAgent.accountError { Text(error).font(.callout).foregroundStyle(.orange) }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct ServiceLoginPage: View {
    @ObservedObject var session: WebAgentSession
    var body: some View {
        EmbeddedServicePage(webView: session.webView)
            .sheet(isPresented: Binding(get: { session.popup != nil }, set: { if !$0 { session.closePopup() } })) {
                VStack(spacing: 0) {
                    HStack {
                        Text("Sign in to \(session.provider.name)").font(.headline)
                        Spacer()
                        Button("Done") { session.closePopup() }
                    }.padding(16)
                    Divider()
                    if let popup = session.popup { EmbeddedServicePage(webView: popup) }
                }.frame(minWidth: 650, minHeight: 650)
            }
    }
}

private struct OnboardingRuntimeView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var setup: OnboardingController
    let runtime: LocalAgentRuntime
    @ObservedObject private var personalAgent: PersonalAgentController
    private var installed: Bool { personalAgent.detectedLocalAgents.contains { $0.runtime == runtime } }

    init(model: AppModel, setup: OnboardingController, runtime: LocalAgentRuntime) {
        self.model = model
        self.setup = setup
        self.runtime = runtime
        personalAgent = model.personalAgent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                AgentAvatar(agent: Agent(name: runtime.name, handles: [], avatar: AgentArtwork.runtimeAvatar(for: runtime)), name: runtime.name, size: 48)
                Text("Set up \(runtime.name)").font(.title.bold())
            }
            Label(runtime == .hermes ? "Comparison reports only" : "Terminal setup only", systemImage: "terminal")
                .font(.headline)
            VStack(alignment: .leading, spacing: 16) {
                if personalAgent.detectingLocalAgents {
                    ProgressView("Checking installation…")
                } else if installed {
                    Label("Command-line app found", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Button("Continue in Terminal") { personalAgent.setUp(runtime) }
                        .buttonStyle(.borderedProminent).disabled(model.demo)
                } else {
                    Text("\(runtime.name) isn’t installed yet.").font(.headline)
                    Link("Install \(runtime.name)", destination: runtime.documentation)
                }
                LocalAgentTerminalInstructions(runtime: runtime)
                Text("msgblast checks installation here, not provider sign-in or model setup. You’ll still need a website, CLI chat, Grok Bot, or Messages agent to start chatting.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if model.demo { Label("Demo installation · Terminal setup is disabled", systemImage: "testtube.2").font(.caption).foregroundStyle(.secondary) }
                if let error = personalAgent.accountError { Text(error).foregroundStyle(.orange) }
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
            Spacer()
            HStack {
                Spacer()
                Button("Done with setup") { setup.completeRuntime(runtime) }
                    .buttonStyle(.borderedProminent).disabled(!installed || personalAgent.detectingLocalAgents)
            }
        }.padding(28)
        .task { await personalAgent.detectLocalAgents() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await personalAgent.detectLocalAgents() }
        }
    }
}

private struct OnboardingContactPicker: View {
    @ObservedObject var model: AppModel
    let choice: OnboardingChoice
    let choose: (Agent) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Choose \(choice == .otherMessages ? "your agent" : choice.name)’s conversation").font(.title2.bold())
            TextField("Search contacts, phone or email", text: $query).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Find onboarding contact")
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(model.contactResults) { agent in
                        HStack(spacing: 12) {
                            AgentAvatar(agent: agent, name: agent.name)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(agent.name).font(.headline)
                                Text(agent.handles.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                                Text(model.route(agent) == nil ? "No conversation yet" : "Existing conversation").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Choose") { choose(agent); dismiss() }
                                .accessibilityLabel("Choose \(agent.name) contact").disabled(model.busy)
                        }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                    }
                    if model.contactResults.isEmpty {
                        Text("Search by name, or enter the phone number or email you use for this agent.")
                            .foregroundStyle(.secondary).padding()
                    }
                }
            }
            if !model.contactStatus.isEmpty { Text(model.contactStatus).font(.caption).foregroundStyle(.orange) }
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 580, height: 470).interactiveDismissDisabled(model.busy)
        .onAppear { query = choice == .otherMessages ? "" : choice.name }
        .task(id: query) {
            model.contactQuery = query
            await model.searchDiscoverContacts(knownAgents: [])
        }
    }
}


private struct OnboardingDiscoveredMessagesView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var setup: OnboardingController
    @State private var agents: [Agent] = []
    @State private var loading = true
    @State private var discoveryError: String?
    @State private var choosingContact = false

    private var displayedAgents: [Agent] {
        let ids = Set((setup.state.discoveredMessageAgentIDs ?? []) + (setup.state.excludedDiscoveredMessageAgentIDs ?? []) + Array(setup.state.messageAgentIDs.values))
        var results = agents
        for saved in model.state.agents where ids.contains(saved.id) {
            if !results.contains(where: { model.savedAgent(matching: $0)?.id == saved.id }) { results.append(saved) }
        }
        return results.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func destinationLabel(_ agent: Agent) -> String {
        guard let chat = model.conversation(agent) else { return agent.handles.joined(separator: ", ") }
        if let name = chat.displayName, !name.isEmpty { return name }
        return chat.handle
    }

    private func included(_ agent: Agent) -> Bool {
        guard let saved = model.savedAgent(matching: agent) else { return false }
        return setup.state.selectedMessageAgentIDs.contains(saved.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Agents we found").font(.system(size: 28, weight: .bold))
            Text("Choose the messaging agents you want to add. You can search for another contact here.")
                .foregroundStyle(.secondary)
            if loading { ProgressView("Finding agents…") }
            else if let discoveryError {
                Text(discoveryError).foregroundStyle(.orange)
                Button("Review Messages permissions") {
                    setup.reviewPermissions()
                }
            }
            else if displayedAgents.isEmpty {
                Text("No known agents found. Choose another Messages agent to pick a contact.")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(displayedAgents) { agent in
                            Button { Task { await setup.toggleDiscoveredMessage(agent) } } label: {
                            HStack(spacing: 16) {
                                Group {
                                    if let photo = agent.avatar, let image = NSImage(data: photo) {
                                        Image(nsImage: image).resizable().scaledToFill()
                                    } else {
                                        Image(systemName: "message.fill")
                                            .font(.system(size: 24)).foregroundStyle(.green)
                                    }
                                }
                                .frame(width: 44, height: 44).clipShape(Circle())
                                .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(agent.name).font(.headline)
                                    Text(destinationLabel(agent)).foregroundStyle(.secondary)
                                    if model.route(agent) == nil || model.conversation(agent)?.businessConversation == true {
                                        Text(model.messageConnectionStatus(agent)).font(.caption).foregroundStyle(.secondary)
                                    }
                                    if agent.handles.count > 1, model.route(agent) != nil, model.conversation(agent)?.businessConversation != true {
                                        Text("Uses your most recent conversation").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Image(systemName: included(agent) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(.blue)
                            }.padding(16)
                                .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                            }.buttonStyle(.plain).disabled(loading || model.busy)
                                .accessibilityLabel("\(included(agent) ? "Deselect" : "Select") \(agent.name)")
                                .accessibilityValue(model.messageConnectionStatus(agent))
                        }
                    }
                }
            }
            Button {
                choosingContact = true
            } label: {
                Label("Search for more agents in Messages", systemImage: "plus.circle")
            }.buttonStyle(.plain)
            Spacer(minLength: 0)
            Divider()
            HStack {
                Button("Back") { setup.reviewPermissions() }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                Button("Add other agents") {
                    setup.edit { $0.reviewMessagesDiscovery(); $0.stage = .choosing }
                }.buttonStyle(.plain).foregroundStyle(.secondary)
                Button("Continue setup") {
                    setup.edit { $0.reviewMessagesDiscovery() }
                    if setup.state.hasConnectedAgent { setup.begin() }
                    else { setup.edit { $0.stage = .choosing } }
                }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(loading || model.busy || setup.state.selected.isEmpty || !(setup.state.approvedPermissionSections ?? []).contains(.messaging))
            }
        }.padding(28)
            .task {
                defer { loading = false }
                guard (setup.state.approvedPermissionSections ?? []).contains(.messaging) else {
                    discoveryError = "Messaging access needs attention. Review permissions before connecting these agents."
                    return
                }
                if setup.state.currentStep == .messages && setup.state.messagesDiscoveryReviewed != false {
                    setup.edit { $0.messagesDiscoveryReviewed = false }
                }
                do {
                    agents = try await model.onboardingContactSuggestions()
                    for agent in agents {
                        let choice = OnboardingChoice.allCases.first(where: { !$0.contactSuggestions(in: [agent]).isEmpty }) ?? .otherMessages
                        if setup.state.connector != nil || setup.state.selected.contains(choice) {
                            await setup.connectDiscoveredMessage(agent, choice: choice)
                        }
                    }
                }
                catch { discoveryError = "Couldn’t find agents: \(error.localizedDescription)" }
            }
            .sheet(isPresented: $choosingContact) {
                OnboardingContactPicker(model: model, choice: .otherMessages) { agent in
                    Task { await setup.connectDiscoveredMessage(agent, choice: .otherMessages) }
                }
            }
    }
}

private struct OnboardingBreadcrumbs: View {
    let activeStep: Int
    private let titles = ["Connect agents", "Start chatting"]

    var body: some View {
        HStack(spacing: 12) {
            ForEach(titles.indices, id: \.self) { index in
                if index > 0 {
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                Text("\(index + 1)  \(titles[index])")
                    .foregroundStyle(index + 1 == activeStep ? Color.blue : .secondary)
                    .accessibilityValue(index + 1 == activeStep ? "Current step" : "")
            }
        }.font(.callout).accessibilityElement(children: .contain)
    }
}
