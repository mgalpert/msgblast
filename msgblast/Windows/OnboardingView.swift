import SwiftUI
import AppKit
import msgblastCore

struct OnboardingView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var setup: OnboardingController

    init(model: AppModel) {
        self.model = model
        setup = model.onboarding
    }

    var body: some View {
        VStack(spacing: 0) {
            if setup.state.stage == .choosing { chooser }
            else if let step = setup.state.currentStep {
                switch step {
                case .agent(let provider):
                    OnboardingProviderView(model: model, setup: setup, session: setup.session(for: provider))
                        .id(provider)
                case .messages:
                    OnboardingMessagesView(model: model, setup: setup)
                case .runtime(let runtime):
                    OnboardingRuntimeView(model: model, setup: setup, runtime: runtime).id(runtime)
                }
            }
            if let error = setup.error ?? model.error {
                Text(error).font(.callout).foregroundStyle(.orange).padding(.horizontal, 28)
            }
            Divider()
            HStack {
                if setup.state.stage == .choosing {
                    Text("Connect at least one agent to continue.").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Continue setup") { setup.begin() }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(setup.state.selected.isEmpty)
                } else {
                    Button("Back") { setup.back() }
                    Spacer()
                    Button("Skip for now") { setup.skip() }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }.padding(24).disabled(model.busy)
        }
        .frame(maxWidth: 840, maxHeight: .infinity)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: 740, minHeight: 700)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Welcome to msgblast").font(.callout).foregroundStyle(.secondary)
                    Text("Which agents do you use?").font(.system(size: 28, weight: .bold))
                    Text("Choose the agents you already use. We’ll help you connect each one.")
                        .foregroundStyle(.secondary)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                    ForEach(OnboardingChoice.allCases) { choice in
                        choiceButton(choice)
                    }
                }
                if model.onboardingPreview {
                    Label("Demo onboarding · accounts and conversations are simulated", systemImage: "testtube.2")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(28).frame(maxHeight: .infinity, alignment: .top)
    }

    private func choiceButton(_ choice: OnboardingChoice) -> some View {
        let selected = setup.state.selected.contains(choice)
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
                Text(choice == .otherMessages ? "Another Messages agent" : choice.name)
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(.primary).lineLimit(2)
                Spacer(minLength: 6)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22)).foregroundStyle(selected ? Color.blue : .secondary)
            }
            .padding(12).frame(maxWidth: .infinity, minHeight: 74, maxHeight: 74, alignment: .leading)
            .background(selected ? Color.blue.opacity(0.12) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Color.blue : Color.primary.opacity(0.14), lineWidth: selected ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).accessibilityLabel("Choose \(choice.name)")
            .accessibilityValue(selected ? "Selected" : "Not selected")
    }

}

private struct OnboardingProviderView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var setup: OnboardingController
    @ObservedObject var session: WebAgentSession
    @ObservedObject private var personalAgent: PersonalAgentController

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
                VStack(alignment: .leading, spacing: 6) {
                    Text("Let’s connect \(session.provider.name)").font(.title.bold())
                    Text(setup.state.hasConnectedAgent ? "Connect this agent, or skip it and finish setup later." : "Connect an agent to start chatting. You can skip this choice and try another.")
                        .foregroundStyle(.secondary)
                }
            }
            if session.provider == .grokbot {
                ScrollView { GrokBotSetupView(session: session, busy: model.busy, selectAfterConnecting: false).padding(2) }.scrollIndicators(.hidden)
            } else if let provider = session.provider.personalAgentProvider {
                cliSetup(provider)
                Spacer()
            } else {
                Text("Sign in with the account you already use. Your question won’t be sent during setup.")
                    .font(.callout).foregroundStyle(.secondary)
                ServiceLoginPage(session: session)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.12)))
            }
            HStack(spacing: 12) {
                if setup.checking || session.loading || session.configuringGrokBot {
                    ProgressView().controlSize(.small)
                    Text(session.grokBotConnectionActivity?.title ?? "Checking connection…")
                        .font(.callout).foregroundStyle(.secondary)
                } else if setup.isReady(session) {
                    Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Text(session.snapshot.reason).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Check again") { Task { await setup.refresh(session) } }
                    .disabled(setup.checking || session.configuringGrokBot)
                Button("Continue") { setup.complete(session) }
                    .buttonStyle(.borderedProminent).disabled(!setup.isReady(session) || setup.checking)
            }
        }.padding(28)
        .task { await setup.refresh(session) }
        .onChange(of: session.snapshot.ready) { _, _ in setup.advanceIfReady(session) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await setup.refresh(session) }
        }
    }

    private func cliSetup(_ provider: PersonalAgentProvider) -> some View {
        let installed = personalAgent.installed.contains { $0.provider == provider }
        return VStack(alignment: .leading, spacing: 18) {
            Text("Use the account and setup you already have in \(session.provider.name).")
                .foregroundStyle(.secondary)
            if session.fixture { Label("Demo account · no provider requests", systemImage: "testtube.2").font(.caption).foregroundStyle(.secondary) }
            if !installed {
                Label("\(session.provider.name) isn’t installed yet", systemImage: "arrow.down.circle")
                Link("Install \(session.provider.name)", destination: URL(string: provider == .codex ? "https://developers.openai.com/codex/cli" : "https://code.claude.com/docs/en/setup")!)
                Text("Return here after installation, then choose Check again.").font(.callout).foregroundStyle(.secondary)
            } else if provider == .claude && setup.compatibility[session.provider] == false {
                Label("Update Claude Code to continue", systemImage: "arrow.clockwise.circle")
                Text(PersonalAgentError.conversationVersionRequired.localizedDescription).font(.callout).foregroundStyle(.secondary)
                Link("Claude Code setup guide", destination: URL(string: "https://code.claude.com/docs/en/setup")!)
            } else {
                Text(session.accountStatus.label).font(.headline)
                if !setup.isReady(session) {
                    Button("Sign in to \(session.provider.name)") { personalAgent.signIn(provider) }
                        .buttonStyle(.borderedProminent).disabled(session.fixture)
                    Text("Finish signing in in Terminal, then return here. We’ll check your connection again.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Text("Your existing tools and permissions still apply.").font(.caption).foregroundStyle(.secondary)
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
            Text(runtime == .hermes
                 ? "Hermes can create comparison reports for your Messages conversations. Chat conversations aren’t connected to msgblast yet."
                 : "You can configure OpenClaw here. Its chat conversations aren’t connected to msgblast yet.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !setup.state.hasConnectedAgent {
                Text("Connect at least one other agent to start chatting.").font(.callout).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 16) {
                if personalAgent.detectingLocalAgents {
                    ProgressView("Checking installation…")
                } else if installed {
                    Label("Installed on this Mac", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Continue in Terminal to choose your provider and finish setup, then return here.").foregroundStyle(.secondary)
                    Button("Continue in Terminal") { personalAgent.setUp(runtime) }
                        .buttonStyle(.borderedProminent).disabled(model.demo)
                } else {
                    Text("\(runtime.name) isn’t installed yet.").font(.headline)
                    Link("Install \(runtime.name)", destination: runtime.documentation)
                    Text("Return here after installation, then choose Check again.").foregroundStyle(.secondary)
                }
                if model.demo { Label("Demo installation · Terminal setup is disabled", systemImage: "testtube.2").font(.caption).foregroundStyle(.secondary) }
                if let error = personalAgent.accountError { Text(error).foregroundStyle(.orange) }
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
            Spacer()
            HStack {
                Spacer()
                Button("Check again") { Task { await personalAgent.detectLocalAgents() } }
                    .disabled(personalAgent.detectingLocalAgents)
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

private struct OnboardingMessagesView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var setup: OnboardingController
    @State private var choosingContact: OnboardingChoice?

    private var choices: [OnboardingChoice] { OnboardingChoice.allCases.filter { $0.isMessages && setup.state.selected.contains($0) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Connect your Messages agents").font(.title.bold())
                Text("We’ll set up access once, then connect the conversations you choose.").foregroundStyle(.secondary)
                if !model.databaseAvailable {
                    MessagesAccessRow(guide: model.accessGuide, check: { setup.checkMessages() })
                } else if !model.contactsAvailable {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Find your agents in Contacts").font(.headline)
                        Text("Allow access so you can choose and confirm the right conversation.").foregroundStyle(.secondary)
                        Button("Connect Contacts") { Task { await model.connectContacts(); setup.checkMessages() } }
                            .buttonStyle(.borderedProminent)
                    }.padding(18).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                }
                ForEach(choices) { choice in messageRow(choice) }
                Text("Sending permission is requested when you send your first message.")
                    .font(.caption).foregroundStyle(.secondary)
                if !model.contactStatus.isEmpty { Text(model.contactStatus).font(.callout).foregroundStyle(.orange) }
            }.padding(28)
        }
        .scrollIndicators(.hidden)
        .task { setup.checkMessages() }
        .onChange(of: model.databaseAvailable) { _, _ in setup.checkMessages(refresh: false) }
        .onChange(of: model.contactsAvailable) { _, _ in setup.checkMessages(refresh: false) }
        .onChange(of: model.chats) { _, _ in setup.checkMessages(refresh: false) }
        .sheet(item: $choosingContact) { choice in
            OnboardingContactPicker(model: model, setup: setup, choice: choice)
        }
    }

    private func messageRow(_ choice: OnboardingChoice) -> some View {
        let completed = setup.state.completed.contains(choice)
        let skipped = setup.state.skipped.contains(choice)
        let candidate = setup.candidate(for: choice)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                AgentAvatar(agent: candidate, name: choice == .otherMessages ? "Your agent" : choice.name, size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(choice == .otherMessages ? "Another Messages agent" : choice.name).font(.headline)
                    if completed { Text("\(choice.name) connected").font(.caption).foregroundStyle(.green) }
                    else if skipped { Text("Skipped for now").font(.caption).foregroundStyle(.secondary) }
                    else if let candidate { Text(candidate.handles.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                if completed { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                else if !skipped {
                    Button("Choose contact") { choosingContact = choice }
                        .accessibilityLabel("Choose contact for \(choice.name)")
                        .disabled(!model.databaseAvailable || !model.contactsAvailable || model.busy)
                    Button("Skip") { setup.edit { $0.skip(choice) } }.buttonStyle(.plain)
                        .foregroundStyle(.secondary).accessibilityLabel("Skip \(choice.name)").disabled(model.busy)
                }
            }
            if let candidate, !completed, !skipped {
                Text("Start a one-to-one conversation with this agent in Messages, then return here.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Open Messages") { setup.openMessages(for: candidate) }
                    Button("Check again") { setup.checkMessages() }
                }
            }
        }.padding(18).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct OnboardingContactPicker: View {
    @ObservedObject var model: AppModel
    @ObservedObject var setup: OnboardingController
    let choice: OnboardingChoice
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Choose \(choice == .otherMessages ? "your agent" : choice.name)’s conversation").font(.title2.bold())
            Text("Confirm the contact and address you already use. No message will be sent.")
                .font(.callout).foregroundStyle(.secondary)
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
                            Button("Use") {
                                Task { if await setup.use(agent, for: choice) { dismiss() } }
                            }.accessibilityLabel("Use \(agent.name)").disabled(model.busy)
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
