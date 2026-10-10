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

    init(model: AppModel) {
        self.model = model
        setup = model.onboarding
    }

    var body: some View {
        VStack(spacing: 0) {
            if setup.state.stage == .choosing { chooser }
            else if setup.state.stage == .importing { browserImport }
            else if setup.state.stage == .feedback { OnboardingFeedbackView() }
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
            if setup.state.stage != .connecting || setup.state.currentStep != .messages {
                Divider()
                HStack {
                    if setup.state.stage == .choosing {
                        Spacer()
                        Button("Continue setup") { setup.begin() }
                            .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                            .disabled(setup.state.selected.isEmpty)
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
        .frame(minWidth: 740, minHeight: 700)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var browserImport: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 12) {
                Label("Choose agents", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                Label("Connect accounts", systemImage: "circle.inset.filled").foregroundStyle(.blue)
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                Text("Start chatting").foregroundStyle(.secondary)
            }.font(.callout).frame(maxWidth: .infinity).padding(.bottom, 22)
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
                VStack(alignment: .leading, spacing: 8) {
                    Text("Which agents do you use?").font(.system(size: 28, weight: .bold))
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
                Text("Share feedback anytime").font(.system(size: 28, weight: .bold))
            }
            if let screenshot = Self.screenshot {
                Image(nsImage: screenshot).resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.12)))
                    .accessibilityLabel("Help menu with Share Feedback highlighted")
            }
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
                } else if setup.isReady(session) {
                    Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Spacer()
                Button("Continue") { setup.complete(session) }
                    .buttonStyle(.borderedProminent).disabled(!setup.isReady(session) || setup.checking)
            }
        }.padding(28)
        .task { await setup.refresh(session) }
        .onChange(of: setup.isReady(session)) { _, _ in setup.advanceIfReady(session) }
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

private struct OnboardingMessagesView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var setup: OnboardingController
    @State private var choosingContact: OnboardingChoice?
    @State private var suggestions: [OnboardingChoice: [Agent]] = [:]
    @State private var proposed: [OnboardingChoice: Agent] = [:]
    @State private var included: Set<OnboardingChoice> = []
    @State private var changedSelection: Set<OnboardingChoice> = []
    @State private var findingContacts = false

    private var choices: [OnboardingChoice] { OnboardingChoice.allCases.filter { $0.isMessages && setup.state.selected.contains($0) } }
    private var accessAvailable: Bool { model.databaseAvailable && model.contactsAvailable }
    private var canContinue: Bool {
        !setup.checking && !model.busy && !findingContacts &&
        (included.isEmpty ? setup.state.hasConnectedAgent : accessAvailable && included.allSatisfy { proposed[$0] != nil })
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 24) {
                VStack(spacing: 10) {
                    Text("Choose who to connect").font(.system(size: 28, weight: .bold))
                }.frame(maxWidth: .infinity).padding(.top, 24)
                if !model.databaseAvailable {
                    MessagesAccessRow(guide: model.accessGuide, check: { model.refresh() }, isOnboarding: true)
                } else if !model.contactsAvailable {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Find your agents in Contacts").font(.headline)
                        Button("Connect Contacts") { Task { await model.connectContacts(); model.refresh() } }
                            .buttonStyle(.borderedProminent)
                    }.padding(18).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                } else {
                    if findingContacts { ProgressView("Looking in Contacts…").controlSize(.small) }
                    VStack(spacing: 10) {
                        ForEach(choices) { choice in messageRow(choice) }
                    }
                }
                if !model.contactStatus.isEmpty { Text(model.contactStatus).font(.callout).foregroundStyle(.orange) }
            }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            Divider()
            HStack(spacing: 18) {
                Button("Back") { setup.back() }.buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                if setup.checking { ProgressView("Connecting…").controlSize(.small) }
                else if accessAvailable { Text("\(included.count) \(included.count == 1 ? "agent" : "agents") selected").font(.callout).foregroundStyle(.secondary) }
                Button(included.isEmpty && setup.state.hasConnectedAgent ? "Continue" : "Connect selected") {
                    Task { await setup.connectMessages(proposed, selected: included) }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!canContinue)
            }.padding(24).disabled(setup.checking || model.busy)
        }
        .task(id: accessAvailable) {
            model.refresh()
            await findSuggestions()
        }
        .sheet(item: $choosingContact) { choice in
            OnboardingContactPicker(model: model, choice: choice) { agent in
                proposed[choice] = agent
                included.insert(choice)
            }
        }
    }

    private func messageRow(_ choice: OnboardingChoice) -> some View {
        let selected = included.contains(choice)
        let contact = proposed[choice]
        let completed = setup.state.completed.contains(choice) && contact.flatMap(model.savedAgent(matching:))?.id == setup.state.messageAgentIDs[choice.rawValue]
        let name = choice == .otherMessages ? contact?.name ?? "Another Messages agent" : choice.name
        let artwork = Agent(name: name, handles: [], avatar: contact?.avatar ?? AgentArtwork.messageAvatar(for: choice))
        let needsConversation = contact.map { model.route($0) == nil } ?? false
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 20) {
                Button {
                    if selected { included.remove(choice) } else { included.insert(choice) }
                    changedSelection.insert(choice)
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 22)).foregroundStyle(selected ? Color.blue : .secondary)
                        AgentAvatar(agent: artwork, name: name, size: 44)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(name).font(.headline).foregroundStyle(.primary).lineLimit(1)
                            if needsConversation { Text("No conversation yet").font(.caption).foregroundStyle(.secondary) }
                        }
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Select \(choice.name)")
                    .accessibilityValue(selected ? "Selected" : "Not selected")
                Menu {
                    ForEach(suggestions[choice, default: []]) { agent in
                        Button("\(agent.name) · \(agent.handles.joined(separator: ", "))") {
                            proposed[choice] = agent
                            included.insert(choice)
                        }
                    }
                    if !suggestions[choice, default: []].isEmpty { Divider() }
                    Button("Search Contacts…") { choosingContact = choice }
                    if needsConversation, let contact {
                        Button("Open Messages") { setup.openMessages(for: contact) }
                    }
                } label: {
                    Text(contact?.handles.joined(separator: ", ") ?? (suggestions[choice, default: []].count > 1 ? "Choose a match" : "Choose contact"))
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }.menuStyle(.borderlessButton).frame(maxWidth: 260, alignment: .leading)
                    .accessibilityLabel("Contact for \(choice.name)")
                Spacer(minLength: 0)
                if completed { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("\(choice.name) connected") }
            }
        }.padding(18).frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
            .background(selected ? Color.blue.opacity(0.09) : .primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Color.blue.opacity(0.55) : .primary.opacity(0.12)))
            .disabled(setup.checking || model.busy)
    }

    private func findSuggestions() async {
        suggestions = [:]
        guard model.contactsAvailable, model.databaseAvailable else { return }
        findingContacts = true
        defer { findingContacts = false }
        do {
            let contacts = try await model.onboardingContactSuggestions()
            guard !Task.isCancelled else { return }
            suggestions = Dictionary(uniqueKeysWithValues: choices.map { ($0, $0.contactSuggestions(in: contacts)) })
            for choice in choices where proposed[choice] == nil && !changedSelection.contains(choice) {
                let matches = suggestions[choice, default: []]
                if let candidate = setup.candidate(for: choice) { proposed[choice] = candidate }
                else if matches.count == 1 { proposed[choice] = matches[0] }
                if proposed[choice] != nil && !setup.state.skipped.contains(choice) { included.insert(choice) }
            }
        } catch {
            guard !Task.isCancelled else { return }
            model.contactStatus = error.localizedDescription
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
