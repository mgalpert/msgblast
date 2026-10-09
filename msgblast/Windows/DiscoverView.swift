import SwiftUI
import AppKit
import msgblastCore

@MainActor
private enum DiscoverResources {
    static let catalog = try? loadCatalog()
    private static var images: [String: NSImage] = [:]
    static var directory: URL? {
        #if SWIFT_PACKAGE
        Bundle.module.resourceURL?.appendingPathComponent("Discover")
        #else
        Bundle.main.resourceURL?.appendingPathComponent("Discover")
        #endif
    }
    private static func loadCatalog() throws -> DiscoverCatalog {
        guard let directory else { throw CocoaError(.fileNoSuchFile) }
        return try JSONDecoder().decode(DiscoverCatalog.self, from: Data(contentsOf: directory.appendingPathComponent("catalog.json")))
    }
    static func image(_ filename: String?) -> NSImage? {
        guard let filename, let directory else { return nil }
        if let image = images[filename] { return image }
        guard let image = NSImage(contentsOf: directory.appendingPathComponent("icons/" + filename)) else { return nil }
        images[filename] = image
        return image
    }
}

struct DiscoverView: View {
    @ObservedObject var model: AppModel
    private let catalog = DiscoverResources.catalog
    @State private var category: DiscoverCategory?
    @State private var actionError: String?
    @FocusState private var searchFocused: Bool
    @State private var showingManualEntry = false
    private var canAdd: Bool { model.databaseAvailable && model.contactsAvailable && !model.busy }
    private var query: String { model.contactQuery }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Discover").font(.largeTitle.bold())
                    Text("Find an agent or add someone you already know.").foregroundStyle(.secondary)
                }
                DiscoverAccessView(model: model)
                Text("Agents in the demo, such as Instinct, are examples. To use your own messaging agents, start a Messages chat with their phone number or email, then connect Messages and Contacts to select or add the existing chat below. Selecting Grok in Agents opens its website; Grok Bot is a separate service.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    HStack(spacing: 9) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search agents, contacts, phone or email", text: $model.contactQuery)
                            .focused($searchFocused)
                            .textFieldStyle(.plain).accessibilityLabel("Search Discover")
                            .onSubmit { Task { await model.searchDiscoverContacts(knownAgents: catalog?.discoverAgents ?? []) } }
                        if !query.isEmpty {
                            Button { model.contactQuery = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                                .buttonStyle(.plain).accessibilityLabel("Clear Discover search")
                        }
                    }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                    Button("Add by phone or email") { showingManualEntry = true }.disabled(!canAdd)
                }
                if model.databaseAvailable && model.contactsAvailable {
                    contactsSection
                }
                if let catalog {
                    HStack {
                        Text("Additional Agents").font(.headline)
                        Text("\(catalog.discoverAgents.count) agents").font(.callout).foregroundStyle(.secondary)
                        Spacer()
                    }
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            categoryButton("All", value: nil)
                            ForEach(DiscoverCategory.allCases, id: \.self) { category in
                                categoryButton(category.rawValue, value: category)
                            }
                        }.padding(.vertical, 3)
                    }.scrollIndicators(.hidden)
                    let agents = catalog.filtered(query: query, category: category)
                    if agents.isEmpty {
                        ContentUnavailableView.search(text: query).frame(maxWidth: .infinity)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), spacing: 16)], spacing: 16) {
                            ForEach(agents) { agent in
                                let saved = savedAgent(for: agent)
                                DiscoverAgentCard(agent: agent, added: saved != nil, busy: saved != nil ? model.busy : !canAdd) {
                                    if let saved { model.removeAgent(saved) }
                                    else { Task { await add(agent) } }
                                }
                            }
                        }.padding(2)
                    }
                } else {
                    ContentUnavailableView("Directory unavailable", systemImage: "sparkle.magnifyingglass", description: Text("The agent directory could not be loaded from this app."))
                }
            }.padding(24)
        }
        .focusedSceneValue(\.discoverSearch, { searchFocused = true })
        .onAppear { refreshAccess() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshAccess() }
        .task(id: DiscoverSearchKey(query: query, contactsAvailable: model.contactsAvailable, databaseAvailable: model.databaseAvailable)) {
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            await model.searchDiscoverContacts(knownAgents: catalog?.discoverAgents ?? [])
        }
        .sheet(isPresented: $showingManualEntry) { ManualAgentEntryView(model: model) }
        .alert("Could not add agent", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK") { actionError = nil }
        } message: { Text(actionError ?? "") }
    }

    private var contactsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("From your contacts").font(.headline)
            if !model.contactStatus.isEmpty { Text(model.contactStatus).font(.callout).foregroundStyle(.secondary) }
            if model.contactResults.isEmpty && query.isEmpty {
                Text("No known agents found in your contacts. You can still search by name, phone number, or email.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(model.contactResults) { agent in contactRow(agent) }
            let saved = model.state.agents.filter { agent in
                (query.isEmpty || agent.name.localizedCaseInsensitiveContains(query) || agent.handles.contains { $0.localizedCaseInsensitiveContains(query) }) &&
                !model.contactResults.contains { $0.contactID == agent.contactID || $0.id == agent.id }
            }
            if !saved.isEmpty {
                Text("Saved").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(saved) { agent in contactRow(agent) }
            }
        }
    }

    private func contactRow(_ agent: Agent) -> some View {
        let saved = model.state.agents.first { saved in
            if let contactID = agent.contactID { return saved.contactID == contactID }
            return saved.handles.contains { handle in agent.handles.contains { ChatResolver.normalize($0) == ChatResolver.normalize(handle) } }
        }
        return HStack(spacing: 12) {
            AgentAvatar(agent: agent, name: agent.name)
            VStack(alignment: .leading, spacing: 3) {
                Text(agent.name).font(.headline)
                Text(model.route(agent) != nil ? "Existing Messages conversation" : (agent.handles.first ?? "No existing chat"))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if let saved {
                Button { model.removeAgent(saved) } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless).disabled(model.busy).help("Remove \(agent.name)")
                    .accessibilityLabel("Remove \(agent.name)")
            } else {
                Button { Task { await model.addAgent(agent) } } label: { Label("Add", systemImage: "plus") }.disabled(!canAdd)
                    .accessibilityLabel("Add \(agent.name)")
            }
        }.padding(14).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }

    private func refreshAccess() {
        model.refresh()
    }

    private func categoryButton(_ title: String, value: DiscoverCategory?) -> some View {
        Button { category = value } label: {
            Text(title).font(.callout.weight(category == value ? .semibold : .regular))
                .padding(.horizontal, 14).padding(.vertical, 7)
                .foregroundStyle(category == value ? .white : .primary)
                .background(category == value ? Color.accentColor : Color(nsColor: .quaternaryLabelColor).opacity(0.25), in: Capsule())
        }.buttonStyle(.plain).accessibilityLabel("Discover category \(title)")
            .accessibilityValue(category == value ? "Selected" : "Not selected")
    }

    private func savedAgent(for agent: DiscoveredAgent) -> Agent? {
        let number = ChatResolver.normalize(agent.number)
        return model.state.agents.first { $0.handles.contains { ChatResolver.normalize($0) == number } }
    }

    private func add(_ entry: DiscoveredAgent) async {
        guard canAdd, savedAgent(for: entry) == nil else { return }
        let avatar = entry.icon.flatMap { filename in
            DiscoverResources.directory.flatMap { try? Data(contentsOf: $0.appendingPathComponent("icons/" + filename)) }
        }
        await model.addAgent(Agent(name: entry.name, handles: [entry.number], avatar: avatar))
        if savedAgent(for: entry) == nil {
            actionError = model.contactStatus.isEmpty ? "This agent could not be added. Try again." : model.contactStatus
        }
    }
}

private struct DiscoverSearchKey: Hashable {
    let query: String
    let contactsAvailable: Bool
    let databaseAvailable: Bool
}

private struct DiscoverAccessView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var guide: MessagesAccessGuide
    init(model: AppModel) { self.model = model; guide = model.accessGuide }

    var body: some View {
        Group {
            if !model.databaseAvailable {
                MessagesAccessRow(guide: guide, check: { model.refresh() })
            } else if !model.contactsAvailable {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        Image(systemName: "person.crop.rectangle").font(.title2).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Connect Contacts").font(.headline)
                            Text("Find the agents already in your contacts.").font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Connect Contacts") { Task { await model.connectContacts() } }
                            .buttonStyle(.borderedProminent).disabled(model.busy)
                    }.padding(14).frame(minHeight: 72)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                    if !model.contactStatus.isEmpty { Text(model.contactStatus).font(.callout).foregroundStyle(.secondary) }
                }
            }
        }
        .onChange(of: guide.flow.stage) { _, stage in
            if stage == .verified { guide.dismissCompletion() }
        }
        .onAppear { if model.databaseAvailable && guide.flow.stage == .verified { guide.dismissCompletion() } }
    }
}

private struct ManualAgentEntryView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var handle = ""
    @State private var error: String?
    private var agent: Agent? {
        guard var agent = Agent.manualAccount(for: handle) else { return nil }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { agent.name = name }
        return agent
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add by phone or email").font(.title2.bold())
            TextField("Name (optional)", text: $name).textFieldStyle(.roundedBorder)
            TextField("Phone number or email", text: $handle).textFieldStyle(.roundedBorder)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add") {
                    guard let agent else { return }
                    Task {
                        await model.addAgent(agent)
                        if model.contactStatus.isEmpty { dismiss() } else { error = model.contactStatus }
                    }
                }.keyboardShortcut(.defaultAction)
                    .disabled(agent == nil || model.busy || !model.databaseAvailable || !model.contactsAvailable)
            }
        }.padding(24).frame(width: 420).interactiveDismissDisabled(model.busy)
    }
}

private struct DiscoverAgentCard: View {
    let agent: DiscoveredAgent
    let added: Bool
    let busy: Bool
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Group {
                    if let image = DiscoverResources.image(agent.icon) {
                        Image(nsImage: image).resizable().scaledToFit()
                    } else {
                        ZStack {
                            RoundedRectangle(cornerRadius: 13).fill(.blue.opacity(0.12))
                            Text(String(agent.name.prefix(1))).font(.title2.bold()).foregroundStyle(.blue)
                        }
                    }
                }.frame(width: 52, height: 52).clipShape(RoundedRectangle(cornerRadius: 13)).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(agent.name).font(.headline).lineLimit(2)
                    Text(agent.discoverCategory?.rawValue ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
            }.frame(height: 56, alignment: .top)
            Text(displayedTagline).font(.callout).foregroundStyle(.secondary)
                .lineLimit(3).frame(height: 54, alignment: .topLeading).frame(maxWidth: .infinity, alignment: .leading)
                .help(displayedTagline)
            HStack {
                if added {
                    Button(action: action) { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).disabled(busy)
                        .accessibilityLabel("Remove \(agent.name)").help("Remove \(agent.name)")
                } else {
                    Button(action: action) { Label("Add", systemImage: "plus").frame(minWidth: 64) }
                        .buttonStyle(.borderedProminent).disabled(busy)
                        .accessibilityLabel("Add \(agent.name)").help("Add to Agents")
                }
                Spacer()
                Link(destination: agent.website) { Label("Website", systemImage: "arrow.up.right") }
                    .font(.callout).accessibilityLabel("\(agent.name) website").help(agent.website.absoluteString)
            }
        }.padding(18).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
            .overlay { RoundedRectangle(cornerRadius: 18).stroke(.quaternary, lineWidth: 1) }
            .accessibilityElement(children: .contain).accessibilityIdentifier("discover-agent-" + agent.id)
    }
    private var displayedTagline: String {
        agent.tagline.replacingOccurrences(of: "imessage", with: "Messages", options: .caseInsensitive)
    }
}
