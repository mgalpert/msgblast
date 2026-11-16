import Foundation
import msgblastCore

enum FeedbackFacts {
    /// This does not read state.json, chat.db, contacts, or draft text from disk.
    @MainActor
    static func capture(model: AppModel?, updater: AppUpdater) -> DiagnosticFacts {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info["CFBundleVersion"] as? String ?? "unknown"
        let bundle = Bundle.main.bundleIdentifier ?? "unknown"
        let system = ProcessInfo.processInfo.operatingSystemVersionString
        let updatesEnabled = updater.configuration.isEnabled
        let updatesReason = updater.configuration.unavailableReason
        guard let model else {
            var facts = DiagnosticFacts(version: version, buildNumber: build, bundleIdentifier: bundle, fixtureMode: false, operatingSystem: system, updatesEnabled: updatesEnabled, updatesReason: updatesReason, messagesStatus: "", permissionStage: "idle", agentCount: 0, comparisonCount: 0, hasDraft: false, attachmentCount: 0, windowStyle: "connected", personalAgent: "", webProviderCounts: [:], lastError: nil, supportFolder: "", stateFilePresent: false, stateFileBytes: 0)
            facts.nativeAppVersions = nativeAppVersions(demo: false)
            return facts
        }
        let state = model.state
        var providers: [String: Int] = [:]
        for comparison in state.comparisons {
            for provider in comparison.webProviders ?? [] {
                providers[provider.rawValue, default: 0] += 1
            }
        }
        let folder = SupportDirectory.folderName(
            demo: model.demo,
            override: Bundle.main.object(forInfoDictionaryKey: "msgblastSupportDirectory") as? String,
            webPreview: Bundle.main.object(forInfoDictionaryKey: "msgblastLiveWebPreview") as? Bool == true,
            bundleIdentifier: bundle)
        let size = (try? model.local.url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]))
        let present = size?.isRegularFile == true && size?.fileSize != nil
        var facts = DiagnosticFacts(
            version: version, buildNumber: build, bundleIdentifier: bundle, fixtureMode: model.demo, operatingSystem: system,
            updatesEnabled: updatesEnabled, updatesReason: updatesReason, messagesStatus: model.databaseStatus,
            permissionStage: permissionStage(model.accessGuide.flow.stage), agentCount: state.agents.count,
            comparisonCount: state.comparisons.count, hasDraft: hasDraft(state), attachmentCount: attachmentCount(state),
            windowStyle: state.effectiveWindowStyle.rawValue, personalAgent: state.personalAgentProvider ?? "",
            webProviderCounts: providers, lastError: model.error, supportFolder: folder,
            stateFilePresent: present, stateFileBytes: present ? (size?.fileSize ?? 0) : 0)
        facts.nativeAppVersions = nativeAppVersions(demo: model.demo)
        return facts
    }

    @MainActor
    private static func nativeAppVersions(demo: Bool) -> [DesktopAppProvider: DiagnosticFacts.NativeAppVersion] {
        if demo {
            return [.claude: .init(version: "4.16336.0", build: "16336"), .muse: .init(version: "12.0", build: "1200")]
        }
        var versions: [DesktopAppProvider: DiagnosticFacts.NativeAppVersion] = [:]
        for app in WebProvider.desktopProviders.compactMap(\.desktopApp) {
            guard let url = DesktopAppInstallation.current(for: app).url, let bundle = Bundle(url: url) else { continue }
            versions[app] = .init(
                version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown")
        }
        return versions
    }

    private static func permissionStage(_ stage: HistoryAccessHandoff.Stage) -> String {
        switch stage {
        case .idle: "idle"
        case .openingSettings: "openingSettings"
        case .guiding: "guiding"
        case .waitingForAccess: "waitingForAccess"
        case .verified: "verified"
        }
    }

    private static func hasDraft(_ state: AppState) -> Bool {
        if !state.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        return state.comparisons.contains { comparison in
            !comparison.allDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || comparison.privateDrafts.values.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
    }

    private static func attachmentCount(_ state: AppState) -> Int {
        var count = state.attachmentsDraft?.count ?? 0
        for comparison in state.comparisons {
            count += comparison.attachments?.count ?? 0
            count += comparison.allAttachmentsDraft?.count ?? 0
            count += comparison.privateAttachmentDrafts?.values.reduce(0) { $0 + $1.count } ?? 0
            count += comparison.members.compactMap(\.payload).flatMap(\.parts).compactMap(\.attachment).count
            for followUp in comparison.followUps {
                count += followUp.payloads?.values.flatMap(\.parts).compactMap(\.attachment).count ?? 0
            }
        }
        return count
    }
}
