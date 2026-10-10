import SwiftUI
import AppKit
import msgblastCore

struct AgentGridView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var web: WebAgents
    @Binding var editing: Bool
    let busy: Bool
    let toggleMessages: (UUID) -> Void
    let openChat: (WebAgentSession) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var avatars
    @State private var query = ""
    @State private var dragging: AgentGridID?
    @GestureState private var dragActive = false
    @State private var previewLayout: AgentGridLayout?
    @State private var tileFrames: [AgentGridID: CGRect] = [:]
    @State private var hovered: AgentGridID?
    @State private var setup: AgentGridID?
    @State private var arrived: AgentGridID?

    private var catalog: [AgentGridEntry] { model.agentGridCatalog }
    private var motion: Animation? { reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.8) }

    var body: some View {
        let entries = catalog
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        let layout = previewLayout ?? model.agentGridLayout
        let shown = layout.visibleIDs.compactMap { byID[$0] }
        let shownIDs = Set(layout.visibleIDs)
        let available = entries.filter {
            !shownIDs.contains($0.id) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query))
        }
        GeometryReader { geometry in
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if editing {
                            HStack(alignment: .firstTextBaseline) {
                                Text("Your agents").font(.headline)
                                Spacer()
                                Text("Drag to reorder · − to hide").font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        if shown.isEmpty {
                            ContentUnavailableView("Choose your agents", systemImage: "person.2",
                                description: Text("Add agents from the list below."))
                        } else {
                            grid(shown, available: false, size: tileSize(geometry), scroll: scroll)
                        }
                        if editing || shown.isEmpty {
                            Divider()
                            VStack(alignment: .leading, spacing: 12) {
                                Text("More agents").font(.headline)
                                Text("Tap + to add to your grid").font(.callout).foregroundStyle(.secondary)
                                HStack(spacing: 8) {
                                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                                    TextField("Search agents", text: $query).textFieldStyle(.plain)
                                        .accessibilityLabel("Search available agents")
                                    if !query.isEmpty {
                                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                                            .buttonStyle(.plain).accessibilityLabel("Clear agent search")
                                    }
                                }.padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                            }
                            if available.isEmpty {
                                Text(query.isEmpty ? "All agents are in your grid." : "No agents match your search.")
                                    .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 20)
                            } else {
                                grid(available, available: true, size: tileSize(geometry), scroll: scroll)
                            }
                            Button("Restore featured") {
                                withAnimation(motion) {
                                    _ = model.setAgentGrid(model.defaultAgentGrid)
                                    query = ""
                                }
                                scrollToTop(scroll)
                            }.buttonStyle(.plain).foregroundStyle(.secondary).disabled(busy)
                                .help("Restore the featured agents and your connected agents in their default order")
                        }
                    }.padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 24)
                        .id("agent-grid-top")
                }.accessibilityIdentifier("Agent grid scroll area")
                    .coordinateSpace(name: "agent-grid")
                    .onPreferenceChange(AgentGridFrames.self) { tileFrames = $0 }
                    .disabled(setup != nil).accessibilityHidden(setup != nil)
            }
            .overlay { if let setup { setupOverlay(setup, geometry: geometry) } }
        }
        .onChange(of: editing) { _, _ in
            query = ""; dragging = nil; previewLayout = nil; hovered = nil; arrived = nil; setup = nil
        }
        .onChange(of: dragActive) { _, active in
            if !active { withAnimation(motion) { previewLayout = nil }; dragging = nil; hovered = nil }
        }
    }

    private func setupOverlay(_ id: AgentGridID, geometry: GeometryProxy) -> some View {
        ZStack {
            Color.black.opacity(0.4)
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(setupTitle(id)).font(.title2.bold())
                    Spacer()
                    Button("Done") { setup = nil }.keyboardShortcut(.cancelAction)
                        .accessibilityLabel("Done setting up \(catalog.first { $0.id == id }?.name ?? "agent")")
                }
                ScrollView {
                    switch id {
                    case .web(.grokbot):
                        if let session = session(for: id) {
                            if session.grokBotIsConfigured && !session.isEnabled {
                                Button("Enable Grok Bot") {
                                    session.updateState { $0.enabled = true; $0.selected = false }
                                    session.connect()
                                }.buttonStyle(.borderedProminent).disabled(busy)
                            }
                            GrokBotSetupView(session: session, busy: busy, selectAfterConnecting: false)
                        }
                    case .web, .runtime:
                        LocalAgentSettingsView(agent: model.personalAgent, web: web, busy: busy)
                    case .featuredMessages(let choice):
                        FeaturedMessagesGridSetup(model: model, choice: choice)
                    case .messages:
                        Text("Open an existing Messages conversation with this agent, then return to msgblast.")
                            .foregroundStyle(.secondary)
                    }
                }
            }.padding(24)
                .frame(width: min(620, geometry.size.width - 40), height: min(560, geometry.size.height - 40))
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(.secondary.opacity(0.2)))
                .shadow(radius: 20)
        }
    }

    private func tileSize(_ geometry: GeometryProxy) -> CGFloat { min(100, max(48, (geometry.size.width - 88) / 3)) }

    // Eager rows keep both sections' avatar frames alive during cross-section motion.
    private func grid(_ entries: [AgentGridEntry], available: Bool, size: CGFloat, scroll: ScrollViewProxy) -> some View {
        AgentGridArrangement {
            ForEach(entries) { entry in
                tile(entry, available: available, size: size, scroll: scroll)
            }
        }
    }

    private func tile(_ entry: AgentGridEntry, available: Bool, size: CGFloat, scroll: ScrollViewProxy) -> some View {
        let tile = AgentGridTile(entry: entry, size: size, avatars: avatars, editing: editing,
            available: available, selected: selected(entry.id), arrived: arrived == entry.id || dragging == entry.id,
            subtitle: available || editing ? nil : subtitle(entry.id),
            action: { if available { add(entry.id, scroll: scroll) } else if !editing { activate(entry.id) } },
            hide: { hide(entry.id) })
            .disabled(busy)
            .id(entry.id.id)
        return Group {
            if editing && !available {
                tile.background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: AgentGridFrames.self,
                            value: [entry.id: geometry.frame(in: .named("agent-grid"))])
                    }
                }
                .highPriorityGesture(DragGesture(minimumDistance: 6, coordinateSpace: .named("agent-grid"))
                    .updating($dragActive) { _, active, _ in active = true }
                    .onChanged { value in
                        guard !busy else { return }
                        if dragging == nil { dragging = entry.id; previewLayout = model.agentGridLayout }
                        guard dragging == entry.id else { return }
                        guard let target = tileFrames.first(where: {
                            $0.key != entry.id && $0.value.contains(value.location)
                        })?.key else { hovered = nil; return }
                        guard hovered != target else { return }
                        hovered = target
                        var layout = previewLayout ?? model.agentGridLayout
                        layout.move(entry.id, to: target)
                        withAnimation(motion) { previewLayout = layout }
                    }
                    .onEnded { _ in
                        if let previewLayout { _ = model.setAgentGrid(previewLayout) }
                        previewLayout = nil; dragging = nil; hovered = nil
                    })
                .accessibilityAction(named: "Move earlier") { move(entry.id, by: -1) }
                .accessibilityAction(named: "Move later") { move(entry.id, by: 1) }
            } else {
                tile.contextMenu {
                    if !available, let session = session(for: entry.id) {
                        Button("Open chat") { openChat(session) }.disabled(busy || !session.isEnabled || !session.state.selected)
                    }
                }
            }
        }
    }

    private func session(for id: AgentGridID) -> WebAgentSession? {
        guard case .web(let provider) = id else { return nil }
        return web.sessions.first { $0.provider == provider }
    }

    private func selected(_ id: AgentGridID) -> Bool {
        if let session = session(for: id) { return session.isEnabled && session.state.selected }
        if let agent = model.messageAgent(for: id) { return model.state.selection.contains(agent.id) }
        return false
    }

    private func subtitle(_ id: AgentGridID) -> String? {
        if case .runtime = id { return "Local setup" }
        if let session = session(for: id), !session.isEnabled { return "Set up" }
        if case .featuredMessages = id, model.messageAgent(for: id) == nil { return "Connect Messages" }
        return nil
    }

    private func activate(_ id: AgentGridID) {
        if let session = session(for: id) {
            if !session.isEnabled || (session.provider == .grokbot && !session.grokBotIsConfigured) { setup = id }
            else { web.toggle(session) }
        } else if let agent = model.messageAgent(for: id), model.route(agent) != nil {
            toggleMessages(agent.id)
        } else { setup = id }
    }

    private func setupTitle(_ id: AgentGridID) -> String {
        "Set up \(catalog.first { $0.id == id }?.name ?? "agent")"
    }

    private func add(_ id: AgentGridID, scroll: ScrollViewProxy) {
        var grid = model.agentGridLayout
        grid.add(id)
        var saved = false
        withAnimation(motion) { saved = model.setAgentGrid(grid); if saved { arrived = id } }
        guard saved else { return }
        Task { @MainActor in
            await Task.yield()
            withAnimation(motion) { scroll.scrollTo("agent-grid-top", anchor: .top) }
            if needsSetup(id) {
                if !reduceMotion { try? await Task.sleep(for: .milliseconds(650)) }
                if setup == nil, arrived == id, model.isVisibleInAgentGrid(id) { setup = id }
            }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            if arrived == id { withAnimation(motion) { arrived = nil } }
        }
    }

    private func needsSetup(_ id: AgentGridID) -> Bool {
        if let session = session(for: id), session.provider.usesNativeConversation {
            return !session.isEnabled || !session.isReadyForOnboarding
        }
        if case .featuredMessages = id { return model.messageAgent(for: id).flatMap(model.route) == nil }
        if case .runtime(let runtime) = id {
            return model.state.onboarding?.completed.contains { $0.runtime == runtime } != true
        }
        return false
    }

    private func scrollToTop(_ scroll: ScrollViewProxy) {
        Task { @MainActor in
            await Task.yield()
            withAnimation(motion) { scroll.scrollTo("agent-grid-top", anchor: .top) }
        }
    }

    private func hide(_ id: AgentGridID) {
        var grid = model.agentGridLayout
        grid.hide(id)
        withAnimation(motion) { _ = model.setAgentGrid(grid); arrived = nil }
    }

    private func move(_ id: AgentGridID, to target: AgentGridID) {
        guard !busy else { return }
        var grid = model.agentGridLayout
        grid.move(id, to: target)
        guard grid != model.agentGridLayout else { return }
        withAnimation(motion) { _ = model.setAgentGrid(grid) }
    }

    private func move(_ id: AgentGridID, by offset: Int) {
        let ids = model.agentGridLayout.shown(in: catalog.map(\.id))
        guard let index = ids.firstIndex(of: id), ids.indices.contains(index + offset) else { return }
        move(id, to: ids[index + offset])
    }
}

private struct AgentGridTile: View {
    let entry: AgentGridEntry
    let size: CGFloat
    let avatars: Namespace.ID
    let editing: Bool
    let available: Bool
    let selected: Bool
    let arrived: Bool
    let subtitle: String?
    let action: () -> Void
    let hide: () -> Void

    var body: some View {
        VStack(spacing: 9) {
            Group {
                if editing && !available {
                    avatar.accessibilityElement(children: .ignore)
                        .accessibilityLabel("Agent \(entry.name)").accessibilityValue("In your grid")
                } else {
                    Button(action: action) { avatar }.buttonStyle(.plain)
                        .accessibilityLabel(available ? "Add \(entry.name)" : entry.name)
                        .accessibilityValue(available ? "Available to add" : subtitle ?? (selected ? "Selected" : "Not selected"))
                }
            }
                .overlay(alignment: .topLeading) {
                    if editing && !available {
                        Button(action: hide) { badge("minus", color: Color(nsColor: .systemGray)) }
                            .buttonStyle(.plain).offset(x: -4, y: -4)
                            .accessibilityLabel("Hide \(entry.name)")
                            .help("Move \(entry.name) to More agents")
                    }
                }
            Text(entry.name).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
            if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
        }.frame(maxWidth: .infinity).contentShape(Rectangle())
    }

    private var avatar: some View {
        AgentAvatar(agent: entry.agent, name: entry.name, size: size)
            .matchedGeometryEffect(id: entry.id, in: avatars)
            .overlay { if arrived { Circle().stroke(.blue.opacity(0.7), lineWidth: 2).padding(-4) } }
            .overlay(alignment: .bottomTrailing) {
                if available { badge("plus", color: .blue) }
                else if !editing && subtitle == nil {
                    if selected { badge("checkmark", color: .blue) }
                    else {
                        Circle().fill(Color(nsColor: .windowBackgroundColor))
                            .overlay(Circle().stroke(.secondary, lineWidth: 1))
                            .frame(width: 24, height: 24).offset(x: 2, y: 2)
                    }
                }
            }
    }

    private func badge(_ symbol: String, color: Color) -> some View {
        Image(systemName: symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
            .frame(width: 24, height: 24).background(color, in: Circle())
            .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
            .offset(x: 2, y: 2)
    }
}

private struct AgentGridFrames: PreferenceKey {
    static var defaultValue: [AgentGridID: CGRect] { [:] }
    static func reduce(value: inout [AgentGridID: CGRect], nextValue: () -> [AgentGridID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

// A flat eager layout preserves the dragged view's identity as it crosses rows.
private struct AgentGridArrangement: Layout {
    private func rowHeights(_ subviews: Subviews, width: CGFloat) -> [CGFloat] {
        var heights = Array(repeating: CGFloat.zero, count: (subviews.count + 2) / 3)
        let columnWidth = max(0, (width - 40) / 3)
        for (index, view) in subviews.enumerated() {
            heights[index / 3] = max(heights[index / 3], view.sizeThatFits(.init(width: columnWidth, height: nil)).height)
        }
        return heights
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        let heights = rowHeights(subviews, width: width)
        return CGSize(width: width, height: heights.reduce(0, +) + CGFloat(max(0, heights.count - 1)) * 28)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let heights = rowHeights(subviews, width: bounds.width)
        let columnWidth = max(0, (bounds.width - 40) / 3)
        var y = bounds.minY
        for (index, view) in subviews.enumerated() {
            if index > 0 && index % 3 == 0 { y += heights[index / 3 - 1] + 28 }
            view.place(at: CGPoint(x: bounds.minX + CGFloat(index % 3) * (columnWidth + 20), y: y),
                anchor: .topLeading, proposal: .init(width: columnWidth, height: nil))
        }
    }
}

private struct FeaturedMessagesGridSetup: View {
    @ObservedObject var model: AppModel
    let choice: OnboardingChoice
    @State private var candidates: [Agent] = []
    @State private var loading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect an existing Messages conversation for \(choice.name).")
                .foregroundStyle(.secondary)
            DiscoverAccessView(model: model)
            if loading { ProgressView("Finding contacts…") }
            ForEach(candidates) { agent in
                HStack(spacing: 12) {
                    AgentAvatar(agent: agent, name: agent.name)
                    Text(agent.name)
                    Spacer()
                    if let saved = model.savedAgent(matching: agent) {
                        Text(model.route(saved) != nil ? "Connected" : "Start a Messages conversation")
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Connect") { Task { await model.addAgent(agent) } }
                            .disabled(model.busy || !model.databaseAvailable || !model.contactsAvailable)
                    }
                    if !model.demo {
                        Button("Open Messages") { model.onboarding.openMessages(for: agent) }
                    }
                }
            }
            if !loading && candidates.isEmpty {
                Text("Save \(choice.name) in Contacts and start a Messages conversation, then check again. You can also add agents from Discover.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Button("Check again") { Task { await refresh() } }.disabled(loading)
            if !model.contactStatus.isEmpty { Text(model.contactStatus).foregroundStyle(.orange) }
        }.task { await refresh() }
    }

    private func refresh() async {
        loading = true
        defer { loading = false }
        model.refresh()
        do { candidates = choice.contactSuggestions(in: try await model.onboardingContactSuggestions()) }
        catch is CancellationError { }
        catch { if !Task.isCancelled { model.error = error.localizedDescription } }
    }
}
