import Foundation
import Combine
import AppKit
import msgblastCore

@MainActor
final class PersonalAgentController: ObservableObject {
    @Published private(set) var installed: [InstalledPersonalAgent] = []
    @Published private(set) var discovering = false
    @Published private(set) var accounts: [PersonalAgentProvider: PersonalAgentAccountStatus] = [:]
    @Published private(set) var checkingAccounts = false
    @Published private(set) var accountError: String?
    @Published private(set) var detectedLocalAgents: [InstalledLocalAgent] = []
    @Published private(set) var detectingLocalAgents = false
    @Published private(set) var errors: [UUID: String] = [:]
    @Published private var tasks: [UUID: Task<Void, Never>] = [:]
    private var discoveryTask: Task<[InstalledPersonalAgent], Never>?
    private var shuttingDown = false
    var running: Set<UUID> { Set(tasks.keys) }
    let demo: Bool

    init(demo: Bool) {
        self.demo = demo
        if demo { accounts = [.codex: .subscription, .claude: .signedOut] }
    }

    func detectLocalAgents() async {
        guard !shuttingDown, !detectingLocalAgents else { return }
        detectingLocalAgents = true
        defer { detectingLocalAgents = false }
        if demo {
            detectedLocalAgents = LocalAgentRuntime.allCases.map { InstalledLocalAgent(runtime: $0, executableURL: URL(fileURLWithPath: "/dev/null")) }
        } else { detectedLocalAgents = await LocalAgentDetection.detect() }
    }

    func refreshAccounts() async {
        guard !demo, !shuttingDown, !checkingAccounts else { return }
        checkingAccounts = true
        defer { checkingAccounts = false }
        await discover()
        accounts = await withTaskGroup(of: (PersonalAgentProvider, PersonalAgentAccountStatus).self) { group in
            for agent in installed where agent.provider == .codex || agent.provider == .claude {
                group.addTask { (agent.provider, await msgblastCore.LocalPersonalAgent.accountStatus(using: agent)) }
            }
            var refreshed: [PersonalAgentProvider: PersonalAgentAccountStatus] = [:]
            for await (provider, status) in group { refreshed[provider] = status }
            return refreshed
        }
    }

    func signIn(_ provider: PersonalAgentProvider) {
        guard !demo, !shuttingDown, let agent = installed.first(where: { $0.provider == provider }) else { return }
        do { openTerminal(script: try LocalPersonalAgent.loginScript(using: agent), purpose: "sign-in") }
        catch { accountError = "Could not open sign-in. Run \(provider.setup) in Terminal." }
    }

    func setUp(_ runtime: LocalAgentRuntime) {
        guard !demo, !shuttingDown,
              let installation = detectedLocalAgents.first(where: { $0.runtime == runtime }) else { return }
        Task {
            let path = await LocalPersonalAgent.executableSearchPath()
            guard !shuttingDown else { return }
            openTerminal(script: LocalAgentDetection.setupScript(using: installation, path: path), purpose: "setup")
        }
    }

    private func openTerminal(script: String, purpose: String) {
        accountError = nil
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("msgblast-Setup-\(UUID()).command")
        do {
            guard FileManager.default.createFile(atPath: url.path, contents: Data(script.utf8), attributes: [.posixPermissions: 0o700]),
                  let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
                throw PersonalAgentError.unavailable("Terminal")
            }
            NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: .init()) { [weak self] _, error in
                if error != nil {
                    try? FileManager.default.removeItem(at: url)
                    Task { @MainActor [weak self] in self?.accountError = "Could not open Terminal for \(purpose). Try again." }
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            accountError = "Could not open Terminal for \(purpose). Try again."
        }
    }

    func discover() async {
        if let discoveryTask { installed = await discoveryTask.value; return }
        discovering = true
        let task = Task { [demo] in
            if demo {
                return [.codex, .claude].map { InstalledPersonalAgent(provider: $0, executableURL: URL(fileURLWithPath: "/dev/null"), path: "") }
            }
            return await LocalPersonalAgent.discover()
        }
        discoveryTask = task
        installed = await task.value
        discoveryTask = nil; discovering = false
    }

    func selectedProvider(model: AppModel) -> PersonalAgentProvider? {
        if let saved = model.state.personalAgentProvider { return PersonalAgentProvider(rawValue: saved) }
        return installed.first?.provider
    }

    func requestReport(_ id: UUID, model: AppModel) async {
        guard !shuttingDown, !running.contains(id) else { return }
        await discover()
        if let provider = selectedProvider(model: model) { summarize(id, provider: provider, model: model) }
    }

    func input(for id: UUID, model: AppModel) throws -> ComparisonSummaryInput {
        guard let comparison = model.comparison(id) else { throw AppFailure.blocked("This comparison is no longer available.") }
        return try ComparisonSummaryInput(comparison: comparison, comparisons: model.state.comparisons, messages: model.messages)
    }

    func summarize(_ id: UUID, provider: PersonalAgentProvider, model: AppModel) {
        guard !shuttingDown, !running.contains(id) else { return }
        errors[id] = nil
        do {
            guard model.databaseAvailable else { throw AppFailure.blocked("Refresh Messages history before summarizing this comparison.") }
            let snapshot = try input(for: id, model: model)
            guard snapshot.responseCount > 0 else { throw AppFailure.blocked("Waiting for the first response. You can summarize as soon as a participant replies.") }
            guard provider.unavailabilityReason == nil else { throw PersonalAgentError.unsupportedProvider(provider) }
            guard let agent = installed.first(where: { $0.provider == provider }) else { throw PersonalAgentError.unavailable(provider.name) }
            // Check storage before starting a provider request that may consume the user's plan.
            try model.save()
            tasks[id] = Task { [weak self, weak model] in
                guard let self, let model else { return }
                defer { self.tasks[id] = nil }
                do {
                    let report: ComparisonReport
                    if self.demo {
                        try await Task.sleep(for: .seconds(1))
                        let sources = "[1] Demo fixture: synthetic comparison criteria.\n[2] Demo fixture: synthetic trial proposal.\n[3] Demo fixture: synthetic context-gap analysis."
                        report = ComparisonReport(
                            overview: "The conversations examine how to compare approaches using clear goals, consistent criteria, and practical evidence. This is a simulated team synthesis.",
                            comparison: "**Context**\nThis is a simulated comparison of approaches. The goal and success criteria still need to be confirmed.\n\n**Shared findings**\n- Clarity, cost, and reversibility are proposed comparison criteria. [1]\n\n**Complementary approach**\n- A small trial is proposed as a way to gather practical evidence against consistent criteria. [2]\n\n**Context gaps**\n- The desired outcome and unclear assumptions are identified as context gaps. [3]\n\n**Tradeoffs**\nDefining criteria makes the decision easier to explain; a trial adds practical evidence but takes effort. Clarifying the goal can change which approach fits.\n\n**Sources**\n\(sources)",
                            uncertainties: ["Which outcome matters most to you: clarity, cost, or reversibility?", "Simulated demo report. No installed agent was contacted."])
                    } else {
                        let response = try await LocalPersonalAgent.summarize(snapshot, using: agent)
                        guard let parsed = ComparisonReport(response: response) else { throw PersonalAgentError.invalidResponse(provider.name) }
                        report = parsed
                    }
                    try Task.checkCancellation()
                    guard let index = model.index(id) else { return }
                    let previous = model.state.comparisons[index].summary
                    model.state.comparisons[index].summary = ComparisonSummary(provider: self.demo ? "Demo analyst (simulated)" : provider.name, report: report, input: snapshot)
                    do { try model.save() }
                    catch { model.state.comparisons[index].summary = previous; throw error }
                } catch is CancellationError {
                    self.errors[id] = "Report cancelled."
                } catch {
                    self.errors[id] = error.localizedDescription
                }
            }
        } catch { errors[id] = error.localizedDescription }
    }

    func cancel(_ id: UUID) { tasks[id]?.cancel() }
    func cancelAll() { for task in tasks.values { task.cancel() } }
    func beginShutdown() { shuttingDown = true }
    func cancelAndWait() async {
        beginShutdown()
        let pending = Array(tasks.values)
        for task in pending { task.cancel() }
        for task in pending { await task.value }
    }
}
