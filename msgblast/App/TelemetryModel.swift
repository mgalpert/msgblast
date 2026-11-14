import AppKit
import msgblastCore

/// Where the send running on this task started. Remote hosts set it around a send; the Mac's own
/// window leaves the default. It travels with the awaited send, so nested send paths need no parameter.
enum TelemetrySendSource {
    @TaskLocal static var current: TelemetryProperties.Source = .mac
}

extension AppModel {
    var needsSharingChoice: Bool {
        reviewingSharingChoice || (state.sharingConsent == nil &&
        (TelemetryCollector.endpoint(demo: demo) != nil ||
         (ProcessInfo.processInfo.arguments.contains("--sharing-preview") &&
          (demo || AppBundleIdentity.isDevelopment(Bundle.main.bundleIdentifier)))))
    }
    @discardableResult
    func saveSharingChoices(_ preferences: SharingPreferences) async -> Bool {
        let previous = state.sharingConsent
        state.sharingConsent = SharingConsent(preferences: preferences, previous: previous)
        do { try save() }
        catch { state.sharingConsent = previous; self.error = "Could not save sharing choices: \(error.localizedDescription)"; return false }
        reviewingSharingChoice = false
        await telemetry.configure(state.sharingConsent)
        lastTelemetryInventory = nil
        lastTelemetryActivityDay = nil
        telemetryHeartbeat()
        return true
    }
    func recordTelemetry(_ name: TelemetryEvent.Name, properties: TelemetryProperties = TelemetryProperties()) {
        guard let event = telemetryEvent(name, properties: properties), let consent = state.sharingConsent else { return }
        Task { await telemetry.record(event, revision: consent.revision) }
    }
    private func telemetryEvent(_ name: TelemetryEvent.Name, properties: TelemetryProperties = TelemetryProperties()) -> TelemetryEvent? {
        guard TelemetryCollector.endpoint(demo: demo) != nil,
              let consent = state.sharingConsent, consent.preferences.allows(name.category) else { return nil }
        var properties = properties
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        if version.range(of: #"^[0-9][0-9A-Za-z._-]{0,31}$"#, options: .regularExpression) != nil { properties.appVersion = version }
        properties.buildChannel = AppBundleIdentity.isDevelopment(Bundle.main.bundleIdentifier) ? .development : .production
        properties.osMajor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        return TelemetryEvent(name: name, properties: properties, consent: consent)
    }
    func telemetryHeartbeat() {
        guard TelemetryCollector.endpoint(demo: demo) != nil, let consent = state.sharingConsent else { return }
        if consent.preferences.agentUsage {
            let inventory = telemetryAgentCounts
            if inventory != lastTelemetryInventory {
                if let previous = lastTelemetryInventory {
                    for (provider, count) in inventory where count > (previous[provider] ?? 0) {
                        var addition = TelemetryProperties(); addition.provider = provider; addition.count = count - (previous[provider] ?? 0)
                        recordTelemetry(.agentAdded, properties: addition)
                    }
                }
                lastTelemetryInventory = inventory
                var properties = TelemetryProperties(); properties.counts = inventory
                recordTelemetry(.agentInventory, properties: properties)
            }
        }
        if consent.preferences.activity && NSApp.isActive {
            let day = consent.cohortStartedAt.map { max(0, Int(Date().timeIntervalSince($0) / 86_400)) } ?? 0
            if day != lastTelemetryActivityDay { lastTelemetryActivityDay = day; recordTelemetry(.appActive) }
        }
    }
    var telemetryAgentCounts: [String: Int] {
        var counts: [String: Int] = [:]
        let configuredChoices = OnboardingChoice.allCases.compactMap { choice -> AgentGridID? in
            guard state.onboarding?.completed.intersection(state.onboarding?.selected ?? []).contains(choice) == true else { return nil }
            if let provider = choice.provider { return .web(provider) }
            if let runtime = choice.runtime { return .runtime(runtime) }
            return nil
        }
        let setupMessages = (state.onboarding?.selectedMessageAgentIDs ?? []).map(AgentGridID.messages)
        let gridIDs = state.agentGrid == nil && state.onboarding != nil && state.onboarding?.isFinished != true
            ? configuredChoices + setupMessages : agentGridLayout.visibleIDs
        for id in gridIDs {
            switch id {
            case .web(let provider): counts[provider.rawValue, default: 0] += 1
            case .webInstance(let agent): counts[agent.provider.rawValue, default: 0] += 1
            case .runtime(let runtime): counts[runtime.rawValue, default: 0] += 1
            case .featuredMessages(let choice): counts[choice.rawValue, default: 0] += 1
            case .messages(let id):
                let agent = state.agents.first { $0.id == id }
                let knownChoice = OnboardingChoice.allCases.first { choice in
                    choice.rawValue == state.onboarding?.messageAgentIDs.first { $0.value == id }?.key ||
                        agent.map { !choice.contactSuggestions(in: [$0]).isEmpty } == true
                }
                counts[knownChoice?.rawValue ?? "otherMessages", default: 0] += 1
            }
        }
        // Approved outside agents, by kind only. Their names never leave the Mac.
        for name in agentControl.gate.approvals.keys {
            counts[AgentControlTailnet.Kind(name: name).telemetryID, default: 0] += 1
        }
        return counts.mapValues { min(100, $0) }
    }
    func recordMessageSubmission(kind: TelemetryProperties.Kind, recipientCount: Int, started: Date, logicalID: UUID) {
        guard TelemetryCollector.endpoint(demo: demo) != nil, recipientCount > 0 else { return }
        guard state.sharingConsent?.preferences.messageCounts == true || state.sharingConsent?.preferences.activity == true || state.sharingConsent?.preferences.reliability == true || state.sharingConsent?.preferences.performance == true else { return }
        let source = TelemetrySendSource.current
        var properties = TelemetryProperties(); properties.kind = kind; properties.recipientCount = min(100, recipientCount); properties.source = source
        var outcome = TelemetryProperties(); outcome.operation = .send; outcome.result = .success; outcome.source = source
        var timing = TelemetryProperties(); timing.operation = .send; timing.duration = .init(seconds: Date().timeIntervalSince(started))
        let events = [telemetryEvent(.messageSubmitted, properties: properties), telemetryEvent(.appEngaged), telemetryEvent(.operationResult, properties: outcome), telemetryEvent(.operationTiming, properties: timing)].compactMap { $0 }
        if let consent = state.sharingConsent {
            Task { await telemetry.recordSubmission(events, revision: consent.revision, logicalID: logicalID) }
        }
        telemetryHeartbeat()
    }
    func recordOperation(_ operation: TelemetryProperties.Operation, success: Bool, started: Date) {
        var outcome = TelemetryProperties(); outcome.operation = operation; outcome.result = success ? .success : .failure
        if operation == .send { outcome.source = TelemetrySendSource.current }
        recordTelemetry(.operationResult, properties: outcome)
        var timing = TelemetryProperties(); timing.operation = operation; timing.duration = .init(seconds: Date().timeIntervalSince(started))
        recordTelemetry(.operationTiming, properties: timing)
    }
    /// One event per website, app, CLI or bot agent in a send, so each agent's reliability shows
    /// separately. Messages contacts are left out: their keys would only say "Messages".
    func recordAgentSendResults(_ attempts: [(WebProvider, WebSendAttempt?)]) {
        let source = TelemetrySendSource.current
        for (provider, attempt) in attempts {
            var properties = TelemetryProperties(); properties.provider = provider.rawValue; properties.source = source
            properties.result = attempt.map { $0.status.confirmsSubmission ? .success : $0.status.isUnresolved ? .uncertain : .failure } ?? .failure
            recordTelemetry(.agentSendResult, properties: properties)
        }
    }
    func recordPhonePaired() { recordTelemetry(.phonePaired) }
    /// At most once per elapsed cohort day, like `app_active`.
    func recordPhoneConnected() {
        guard let start = state.sharingConsent?.cohortStartedAt else { return }
        let day = max(0, Int(Date().timeIntervalSince(start) / 86_400))
        guard day != lastTelemetryPhoneDay else { return }
        lastTelemetryPhoneDay = day
        recordTelemetry(.phoneConnected)
    }
}
