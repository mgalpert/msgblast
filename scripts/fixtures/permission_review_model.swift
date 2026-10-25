import AppKit
import msgblastCore

extension SideChatModelCheck {
    @MainActor static func runPermissionReviewRelaunchChecks() async throws {
        let model = AppModel()
        let root = model.local.url.deletingLastPathComponent()
        precondition(root.lastPathComponent.hasPrefix("msgblast-PermissionReview-"))
        defer { try? FileManager.default.removeItem(at: root) }
        model.state.onboarding = nil
        model.state.agentGrid = nil
        model.state.draft = "Permission review restart keeps this draft"
        let agent = model.state.agents[0]
        model.state.selection = [agent.id]
        model.webAgents.session(for: .grok)!.updateState { $0.selected = true }
        let grid = model.agentGridLayout
        let counts = model.telemetryAgentCounts
        try model.save()
        precondition(model.onboarding.checkpointPermissionChange())
        let legacyRestart = AppModel()
        defer { legacyRestart.timer?.invalidate(); legacyRestart.telemetryTimer?.invalidate() }
        precondition(legacyRestart.needsOnboarding && legacyRestart.onboarding.state.needsPermissionSetup,
                     "Settings permission handoff must reopen Allow access for users whose saved setup predates onboarding")
        precondition(legacyRestart.onboarding.state.isFinished,
                     "Permission recovery must not restart agent selection or connection setup")
        precondition(legacyRestart.state.selection == [agent.id] && legacyRestart.state.agentGrid == grid)
        precondition(legacyRestart.state.draft == "Permission review restart keeps this draft")
        precondition(legacyRestart.webAgents.session(for: .grok)!.state.selected)
        await legacyRestart.onboarding.refreshPermissions()
        precondition(!legacyRestart.onboarding.permissionSetupReady,
                     "Existing Messages agents require their complete access group, even when App access is available")
        await legacyRestart.onboarding.messagesPermissions.enableContacts(model: legacyRestart)
        await legacyRestart.onboarding.finishPermissionSetup()
        precondition(!legacyRestart.needsOnboarding,
                     "Completing access must return a previously finished user directly to their workspace")
        precondition(legacyRestart.state.selection == [agent.id] && legacyRestart.state.agentGrid == grid)
        print("PASS: Settings permission handoff for a pre-onboarding profile survives a real AppModel restart, opens Allow access, and returns to the preserved workspace without repeating setup.")

        var finished = legacyRestart.onboarding.state
        finished.selected = [.chatgptApp, .claudeApp, .otherMessages]
        finished.completed = [.chatgptApp]
        finished.skipped = [.claudeApp]
        finished.stage = .finished
        legacyRestart.state.onboarding = finished
        precondition(legacyRestart.onboarding.checkpointPermissionChange())
        let finishedRestart = AppModel()
        defer { finishedRestart.timer?.invalidate(); finishedRestart.telemetryTimer?.invalidate() }
        precondition(finishedRestart.needsOnboarding && finishedRestart.onboarding.state.needsPermissionSetup,
                     "The main scene must honor a permission checkpoint even when setup is finished")
        precondition(finishedRestart.onboarding.state.selected == finished.selected &&
                     finishedRestart.onboarding.state.completed == finished.completed &&
                     finishedRestart.onboarding.state.skipped == finished.skipped)
        precondition(finishedRestart.state.draft == "Permission review restart keeps this draft")
        precondition(finishedRestart.state.selection == [agent.id] && finishedRestart.state.agentGrid == grid)
        print("PASS: finished setup restarts at Allow access with selected, connected and skipped agents, recipients, draft and layout intact.")

        finishedRestart.state.agentGrid = AgentGridLayout(visibleIDs: [.web(.chatgptApp)])
        finishedRestart.webAgents.session(for: .web(.chatgptApp))!.updateState { $0.enabled = true }
        finishedRestart.state.onboarding = finished
        try finishedRestart.save()
        let appOnlyRestart = AppModel()
        defer { appOnlyRestart.timer?.invalidate(); appOnlyRestart.telemetryTimer?.invalidate() }
        await appOnlyRestart.onboarding.resumePermissionsAtLaunch()
        precondition(appOnlyRestart.needsOnboarding && !appOnlyRestart.onboarding.permissionSetupReady,
                     "Startup must require all five grants even when only App Agents are enabled")
        await appOnlyRestart.onboarding.skipPermissionSetup()
        precondition(!appOnlyRestart.needsOnboarding && appOnlyRestart.onboarding.state.permissionsSkipped == true)
        let skippedRestart = AppModel()
        defer { skippedRestart.timer?.invalidate(); skippedRestart.telemetryTimer?.invalidate() }
        await skippedRestart.onboarding.resumePermissionsAtLaunch()
        precondition(!skippedRestart.needsOnboarding && skippedRestart.onboarding.state.permissionsSkipped == true,
                     "An explicit Skip for now must survive a real restart without nagging again")
        precondition(skippedRestart.state.draft == "Permission review restart keeps this draft" &&
                     skippedRestart.state.selection == [agent.id])
        precondition(skippedRestart.onboarding.checkpointPermissionChange())
        let retriedCheckpoint = try skippedRestart.local.load().onboarding
        precondition(retriedCheckpoint?.needsPermissionSetup == true && retriedCheckpoint?.permissionsSkipped == false,
                     "Retrying access from Settings must save a new restart checkpoint and clear the previous skip")
        appOnlyRestart.state.onboarding = retriedCheckpoint
        appOnlyRestart.onboarding = OnboardingController(model: appOnlyRestart, appPermissions: CuaPermissionsController(demoInitiallyAllowed: false))
        await appOnlyRestart.onboarding.resumePermissionsAtLaunch()
        precondition(appOnlyRestart.needsOnboarding && !appOnlyRestart.onboarding.permissionSetupReady,
                     "Startup must also require missing App access")
        precondition(appOnlyRestart.onboarding.state.selected == finished.selected &&
                     appOnlyRestart.onboarding.state.completed == finished.completed &&
                     appOnlyRestart.onboarding.state.skipped == finished.skipped,
                     "Revoked access must not erase finished agent setup")
        let deniedCheckpoint = try appOnlyRestart.local.load().onboarding
        precondition(deniedCheckpoint == appOnlyRestart.state.onboarding)
        appOnlyRestart.onboarding.appPermissions.enableHostAccessibility(demo: true)
        await appOnlyRestart.onboarding.finishPermissionSetup()
        precondition(appOnlyRestart.needsOnboarding, "Device Control alone must not bypass Screen Recording")
        appOnlyRestart.onboarding.appPermissions.enableScreenCapture(demo: true)
        await appOnlyRestart.onboarding.finishPermissionSetup()
        precondition(appOnlyRestart.needsOnboarding, "Both App grants must not bypass missing Contacts access")
        await appOnlyRestart.onboarding.messagesPermissions.enableContacts(model: appOnlyRestart)
        await appOnlyRestart.onboarding.finishPermissionSetup()
        precondition(!appOnlyRestart.needsOnboarding && appOnlyRestart.onboarding.state.stage == .finished)
        precondition(appOnlyRestart.onboarding.state.selected == finished.selected &&
                     appOnlyRestart.onboarding.state.completed == finished.completed &&
                     appOnlyRestart.onboarding.state.skipped == finished.skipped)
        precondition(appOnlyRestart.state.draft == "Permission review restart keeps this draft" &&
                     appOnlyRestart.state.selection == [agent.id])
        precondition(appOnlyRestart.webAgents.session(for: .web(.chatgptApp))!.state.attempts.isEmpty)
        print("PASS: actual launch checks require all five grants, preserve Skip for now across restart, resume a Settings retry, reject partial grants, and return to the saved workspace after simulated approval without sending.")
        var legacyFinished = finished
        legacyFinished.permissionsCompleted = nil
        legacyFinished.permissionsSkipped = nil
        appOnlyRestart.state.onboarding = legacyFinished
        try appOnlyRestart.save()
        let approvedLegacyRestart = AppModel()
        defer { approvedLegacyRestart.timer?.invalidate(); approvedLegacyRestart.telemetryTimer?.invalidate() }
        await approvedLegacyRestart.onboarding.refreshPermissions()
        await approvedLegacyRestart.onboarding.messagesPermissions.enableContacts(model: approvedLegacyRestart)
        await approvedLegacyRestart.onboarding.resumePermissionsAtLaunch()
        precondition(approvedLegacyRestart.onboarding.permissionSetupReady && !approvedLegacyRestart.needsOnboarding,
                     "A fully approved finished legacy profile with missing permission fields must stay in its workspace")
        precondition(approvedLegacyRestart.onboarding.state.selected == finished.selected)
        var unfinished = finished
        unfinished.stage = .connecting
        unfinished.selected.remove(.otherMessages)
        unfinished.skipped = []
        appOnlyRestart.state.onboarding = unfinished
        precondition(appOnlyRestart.onboarding.state.currentStep == .agent(.claudeApp))
        await appOnlyRestart.onboarding.skipPermissionSetup()
        let unfinishedRestart = AppModel()
        defer { unfinishedRestart.timer?.invalidate(); unfinishedRestart.telemetryTimer?.invalidate() }
        await unfinishedRestart.onboarding.resumePermissionsAtLaunch()
        precondition(unfinishedRestart.needsOnboarding && !unfinishedRestart.onboarding.state.needsPermissionSetup &&
                     unfinishedRestart.onboarding.state.permissionsSkipped == true && unfinishedRestart.onboarding.state.stage == .connecting &&
                     unfinishedRestart.onboarding.state.currentStep == .agent(.claudeApp),
                     "Skipping access during unfinished setup must retain the pending step across AppModel restart")
        precondition(unfinishedRestart.onboarding.state.selected == unfinished.selected &&
                     unfinishedRestart.state.draft == "Permission review restart keeps this draft")
        print("PASS: approved legacy finished profiles avoid repeated setup, and unfinished permission skips preserve the pending step and draft across a real AppModel restart.")
        appOnlyRestart.webAgents.session(for: .web(.chatgptApp))!.updateState { $0.enabled = false }

        model.state.onboarding = nil
        model.state.agentGrid = nil
        model.onboarding.reviewMessagesAgents()
        let relaunched = AppModel()
        precondition(relaunched.state.selection == [agent.id])
        precondition(relaunched.webAgents.session(for: .grok)!.state.selected)
        precondition(relaunched.state.draft == "Permission review restart keeps this draft")
        precondition(relaunched.state.agentGrid == grid)
        precondition(relaunched.telemetryAgentCounts == counts)
        print("PASS: actual same-store AppModel relaunch preserves Messages and website recipients, draft, inferred grid, and adoption baseline during permission review.")

        var legacyAppsOnly = OnboardingState()
        legacyAppsOnly.completePermissions(messaging: true, apps: true)
        legacyAppsOnly.selected = [.wabi, .otherMessages]
        legacyAppsOnly.messageAgentIDs["otherMessages"] = agent.id
        legacyAppsOnly.discoveredMessageAgentIDs = [agent.id]
        relaunched.state.onboarding = legacyAppsOnly
        try relaunched.save()
        await relaunched.onboarding.refreshPermissions()
        precondition(relaunched.onboarding.state.approvedPermissionSections == [.apps])
        precondition(relaunched.onboarding.state.selected == [.wabi], "Refreshing a resumed chooser must remove its invisible Messages prerequisite")
        precondition(relaunched.onboarding.state.messageAgentIDs["otherMessages"] == agent.id)
        let savedLegacyMigration = try relaunched.local.load().onboarding
        precondition(savedLegacyMigration == relaunched.onboarding.state)
        relaunched.onboarding.begin()
        precondition(relaunched.onboarding.state.needsPermissionSetup && relaunched.onboarding.state.stage == .choosing,
                     "A legacy partial grant must return to Allow access before connecting apps")
        print("PASS: resumed apps-only chooser drops the hidden legacy Messages prerequisite through real permission refresh, saves the migration, retains agent identity, and requires the remaining permissions before connecting.")

        for completed: Set<OnboardingChoice> in [[], [.wabi]] {
            var deferred = OnboardingState()
            deferred.completePermissions(messaging: true, apps: true)
            deferred.selected = completed.union([.geminiApp])
            deferred.completed = completed
            deferred.stage = .connecting
            relaunched.state.onboarding = deferred
            try relaunched.save()
            let reopened = AppModel()
            let expectedStage: OnboardingState.Stage = completed.isEmpty ? .choosing : .feedback
            precondition(reopened.onboarding.state.stage == expectedStage, "A deferred final connection must not reopen a blank page")
            precondition(reopened.onboarding.state.selected == deferred.selected)
            precondition(reopened.onboarding.state.completed == deferred.completed)
            precondition(reopened.onboarding.state.skipped == deferred.skipped)
            let savedReopened = try reopened.local.load().onboarding
            precondition(savedReopened == reopened.onboarding.state)
        }
        print("PASS: actual AppModel reopens Gemini-only setup at choosing and completed-Wabi setup at feedback, preserving and saving raw selections and completion.")

        var progress = OnboardingState()
        progress.selected = [.chatgptApp, .claudeApp, .codexCLI, .fo]
        progress.completed = [.chatgptApp]
        progress.skipped = [.claudeApp]
        progress.messageAgentIDs[OnboardingChoice.fo.rawValue] = agent.id
        progress.discoveredMessageAgentIDs = [agent.id]
        progress.excludedDiscoveredMessageAgentIDs = [model.state.agents[1].id]
        progress.messagesDiscoveryReviewed = false
        progress.stage = .connecting
        precondition(progress.completePermissions(messaging: true, apps: true))
        let pendingStep = progress.currentStep
        precondition(pendingStep == .agent(.codexCLI))
        relaunched.state.onboarding = progress
        try relaunched.save()
        precondition(relaunched.onboarding.checkpointPermissionChange())
        var checkpoint = progress
        checkpoint.preparePermissionChange()
        let savedCheckpoint = try relaunched.local.load().onboarding
        precondition(savedCheckpoint == checkpoint, "Permission handoff must synchronously persist its checkpoint before macOS can restart the app")

        let resumed = AppModel()
        resumed.onboarding = OnboardingController(model: resumed, appPermissions: CuaPermissionsController(demoInitiallyAllowed: false))
        defer {
            for instance in [model, relaunched, resumed] {
                instance.timer?.invalidate()
                instance.telemetryTimer?.invalidate()
            }
        }
        precondition(resumed.state.onboarding == checkpoint && resumed.onboarding.state.needsPermissionSetup)
        precondition(resumed.state.selection == [agent.id])
        precondition(resumed.state.agentGrid == grid && resumed.state.draft == "Permission review restart keeps this draft")
        precondition(resumed.onboarding.permissionChecksBusy && !resumed.onboarding.permissionSetupReady)
        await resumed.onboarding.finishPermissionSetup()
        precondition(resumed.state.onboarding == checkpoint, "Freshly relaunched controllers must not accept saved grants before checking current permissions")
        await resumed.onboarding.refreshPermissions()
        precondition(!resumed.onboarding.permissionChecksBusy && !resumed.onboarding.permissionSetupReady)
        await resumed.onboarding.finishPermissionSetup()
        precondition(resumed.state.onboarding == checkpoint, "Settled denied permissions must reject both saved approved sections")
        resumed.onboarding.appPermissions.enableHostAccessibility(demo: true)
        resumed.onboarding.appPermissions.enableScreenCapture(demo: true)
        await resumed.onboarding.finishPermissionSetup()
        precondition(resumed.onboarding.state == checkpoint && !resumed.onboarding.permissionSetupReady,
                     "Both App grants must not complete setup while Messaging access is missing")
        precondition(resumed.onboarding.state.selected == progress.selected && resumed.onboarding.state.currentStep == pendingStep)
        resumed.state.onboarding = checkpoint
        await resumed.onboarding.messagesPermissions.enableContacts(model: resumed)
        await resumed.onboarding.refreshPermissions()
        precondition(resumed.onboarding.permissionSetupReady)
        await resumed.onboarding.finishPermissionSetup()
        precondition(resumed.state.onboarding == progress, "Rechecking permissions must resume the exact selected/completed/skipped setup without restarting agent connections")
        precondition(resumed.onboarding.state.currentStep == pendingStep && resumed.onboarding.state.stage == .connecting)
        let savedResumedProgress = try resumed.local.load().onboarding
        precondition(savedResumedProgress == progress)
        print("PASS: actual OnboardingController checkpoints native/CLI/Messages setup through LocalStore, rejects unchecked grants after AppModel relaunch, and resumes the exact saved connection step after fresh simulated permission checks.")

        var checklist = OnboardingState()
        checklist.selected = [.chatgptApp, .dotsApp, .claudeApp, .wabi]
        checklist.stage = .connecting
        precondition(checklist.completePermissions(messaging: true, apps: true))
        resumed.state.onboarding = checklist
        try resumed.save()
        precondition(resumed.onboarding.pendingDesktopSessions.count == 4)
        resumed.onboarding.completeDesktopConnections(checked: [.chatgptApp], skipped: [])
        precondition(resumed.state.onboarding == checklist, "An incomplete checklist cannot advance or discard unchecked apps")
        for provider in [WebProvider.chatgptApp, .dotsApp, .claudeApp] {
            let session = resumed.onboarding.session(for: provider)
            resumed.onboarding.prepareDesktopConnection(session)
            await session.connectDesktopConversation()
            precondition(session.isReadyForOnboarding)
            precondition(session.state.attempts.isEmpty, "A connection check must never submit a prompt")
        }
        resumed.state.onboarding?.approvedPermissionSections = [.messaging]
        let unavailableAppAccess = resumed.onboarding.state
        resumed.onboarding.completeDesktopConnections(checked: [.chatgptApp, .dotsApp, .claudeApp], skipped: [.wabi])
        precondition(resumed.onboarding.state == unavailableAppAccess, "Earlier connection results cannot bypass missing App access after a permission change")
        resumed.state.onboarding = checklist
        resumed.onboarding.completeDesktopConnections(checked: [.chatgptApp, .dotsApp, .claudeApp], skipped: [.wabi])
        let connected = resumed.onboarding.state
        precondition(connected.stage == .feedback)
        precondition(connected.completed == [.chatgptApp, .dotsApp, .claudeApp] && connected.skipped == [.wabi])
        // Saved completion is not a fresh process's live app connection.
        resumed.onboarding.session(for: .chatgptApp).updateState { $0.comparisonID = UUID() }
        precondition(!resumed.onboarding.session(for: .chatgptApp).desktopReady)
        var reviewConnections = connected
        reviewConnections.chooseAgain()
        resumed.state.onboarding = reviewConnections
        await resumed.onboarding.refreshPermissions()
        resumed.onboarding.begin()
        precondition(resumed.onboarding.state.stage == .connecting &&
                     resumed.onboarding.state.pendingChoices == [.chatgptApp],
                     "A saved Ready result without a current connection must return to that app's connection check, not skip to final setup")
        precondition(resumed.onboarding.state.completed == [.dotsApp, .claudeApp] &&
                     resumed.onboarding.state.skipped == [.wabi],
                     "Rechecking a stale connection must retain the other completed and explicitly skipped choices")
        precondition(resumed.onboarding.session(for: .chatgptApp).state.attempts.isEmpty,
                     "Recovering setup must not send a prompt")
        resumed.state.onboarding = connected
        try resumed.save()
        let savedChecklist = try resumed.local.load().onboarding
        precondition(savedChecklist == connected, "The compact checklist must save connected and explicitly skipped agents together")
        resumed.onboarding = OnboardingController(model: resumed, appPermissions: CuaPermissionsController(demoInitiallyAllowed: false))
        await resumed.onboarding.refreshPermissions()
        resumed.state.onboarding = connected
        await resumed.onboarding.finish()
        precondition(!resumed.onboarding.state.isFinished && resumed.onboarding.state.completed.isEmpty,
                     "Final setup must reject earlier Ready results after App access is revoked, even while Messaging remains allowed")
        precondition(resumed.onboarding.state.approvedPermissionSections == [.messaging])
        resumed.onboarding = OnboardingController(model: resumed)
        resumed.state.onboarding = progress
        try resumed.save()
        print("PASS: native connection checklist rejects partial completion, checks three selected apps without sending, and atomically saves verified or explicitly skipped choices.")

        let denied = AppModel()
        defer { denied.timer?.invalidate(); denied.telemetryTimer?.invalidate() }
        denied.state.onboarding = progress
        denied.onboarding = OnboardingController(model: denied, appPermissions: CuaPermissionsController(demoInitiallyAllowed: false))
        let savedBytes = try Data(contentsOf: resumed.local.url)
        let backup = resumed.local.url.appendingPathExtension("checkpoint-backup")
        try FileManager.default.moveItem(at: resumed.local.url, to: backup)
        try FileManager.default.createDirectory(at: resumed.local.url, withIntermediateDirectories: false)
        defer {
            try? FileManager.default.removeItem(at: resumed.local.url)
            try? FileManager.default.moveItem(at: backup, to: resumed.local.url)
        }
        precondition(!resumed.onboarding.checkpointPermissionChange(), "A failed durable save must prevent the permission handoff")
        precondition(resumed.state.onboarding == progress && resumed.onboarding.error != nil)
        resumed.onboarding.reviewStats()
        precondition(!resumed.reviewingSharingChoice && resumed.state.onboarding == progress, "A failed checkpoint must also prevent navigating away to the stats choice")
        let preservedBytes = try Data(contentsOf: backup)
        precondition(preservedBytes == savedBytes, "Storage failure must preserve the last durable setup")
        await denied.onboarding.refreshPermissions()
        precondition(!denied.onboarding.permissionChecksBusy && !denied.onboarding.permissionSetupReady)
        precondition(denied.onboarding.state.needsPermissionSetup && denied.onboarding.state.approvedPermissionSections?.isEmpty == true)
        let blocked = denied.onboarding.state
        denied.onboarding.begin()
        precondition(denied.onboarding.state == blocked && denied.onboarding.error != nil,
                     "A failed revocation save must leave later stages blocked in memory")
        let bytesAfterRevocationFailure = try Data(contentsOf: backup)
        precondition(bytesAfterRevocationFailure == savedBytes)
        print("PASS: actual controller rolls back permission checkpoints and blocks stats navigation when the isolated state path cannot be written; the last saved progress remains intact.")
    }
}
