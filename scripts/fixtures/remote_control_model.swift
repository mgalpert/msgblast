import AppKit
import CryptoKit
import Foundation
import SwiftUI
import msgblastCore
import msgblastRemoteProtocol

/// Remote commands through the actual AppModel send paths, in the isolated Demo profile.
/// Simulated Messages and local website fixtures only: no real send, port, or permission.
extension SideChatModelCheck {
    @MainActor static func runRemoteControlChecks() async throws {
        let model = AppModel()
        precondition(model.demo, "The remote fixture runs only in the isolated Demo profile")
        let macDraft = model.state.draft
        precondition(!macDraft.isEmpty)
        final class Settings { var value = RemoteSettings() }
        let settings = Settings()
        settings.value.allowMessagesSends = true
        let power = MacPowerState(readLocked: { false }, observe: false)
        let keepAwake = RemoteKeepAwake(settingEnabled: true, assertions: .init(create: { _ in 1 }, release: { _ in }))
        let availability = AvailabilityModel(sessions: { model.webAgents.sessions }, inputs: { model.remoteAvailabilityInputs(settings: settings.value) })
        await model.remoteAvailabilityProbe(slow: false)
        let host = AppRemoteHost(model: model, availability: availability, keepAwake: keepAwake, power: power, settings: { settings.value })
        let executor = RemoteCommandExecutor(host: host)
        let cedar = model.state.agents[0], lumen = model.state.agents[1]
        let cedarID = RemoteAgentIDs.messages(cedar.id)
        precondition(availability.availability(for: cedarID)?.readiness == .ready, "\(String(describing: availability.availability(for: cedarID)))")

        // A Messages-only new conversation from the phone leaves the Mac composer alone.
        let ask = RemoteCommand(action: .createConversation(text: "Remote ask", agentIDs: [cedarID], attachmentIDs: []))
        let created = await executor.execute(ask)
        precondition(created.outcome == .applied, "\(created)")
        let first = created.conversationID!
        precondition(model.comparison(first)?.members.map(\.id) == [cedar.id])
        precondition(created.agentStatuses[cedarID] == .submitted)
        precondition(model.state.draft == macDraft, "Remote sends never take or clear the Mac's draft")
        precondition(model.error == nil)
        try await waitUntil { model.comparison(first)?.members.first?.anchor != nil }

        // A replayed command id returns the stored result and sends nothing.
        let count = model.state.comparisons.count
        let replay = await executor.execute(ask)
        precondition(replay.replayed && replay.conversationID == first && model.state.comparisons.count == count)

        // A private follow-up uses the phone's text; the Mac's own drafts and files stay put.
        let index = model.index(first)!
        model.state.comparisons[index].allDraft = "Mac shared draft"
        model.state.comparisons[index].privateDrafts[cedar.id.uuidString] = "Mac private draft"
        let macFile = try model.local.stage(Data("mac draft file".utf8), filename: "mac-draft.txt")
        model.state.comparisons[index].privateAttachmentDrafts = [cedar.id.uuidString: [macFile]]
        let followUp = await executor.execute(RemoteCommand(action: .sendPrivate(conversationID: first, agentID: cedarID, text: "Remote private", attachmentIDs: [])))
        precondition(followUp.outcome == .applied, "\(followUp)")
        let sent = model.comparison(first)!.followUps.last!
        precondition(sent.text == "Remote private" && sent.memberIDs == [cedar.id] && sent.payloads == nil, "The Mac's draft file was not sent")
        precondition(model.comparison(first)!.privateDrafts[cedar.id.uuidString] == "Mac private draft")
        precondition(model.comparison(first)!.privateAttachmentDrafts?[cedar.id.uuidString]?.map(\.id) == [macFile.id])
        precondition(model.comparison(first)!.allDraft == "Mac shared draft")
        precondition(FileManager.default.fileExists(atPath: macFile.path))

        // A remote attachment is staged, sent with the follow-up, and kept by the conversation.
        let upload = UUID(), bytes = Data("remote photo".utf8)
        _ = await executor.execute(RemoteCommand(action: .uploadAttachmentChunk(uploadID: upload, filename: "remote.txt", index: 0, count: 1, data: bytes)))
        let staged = await executor.execute(RemoteCommand(action: .attachStaged(uploadID: upload, sha256: Data(SHA256.hash(data: bytes)))))
        precondition(staged.outcome == .applied && staged.attachmentID != nil, "\(staged)")
        let withFile = await executor.execute(RemoteCommand(action: .sendShared(conversationID: first, text: "See file", agentIDs: [], attachmentIDs: [staged.attachmentID!])))
        precondition(withFile.outcome == .applied, "\(withFile)")
        precondition(model.comparison(first)!.followUps.last!.payloads?[cedar.id.uuidString]?.parts.compactMap(\.attachment).map(\.filename) == ["remote.txt"])
        precondition(model.comparison(first)!.allDraft == "Mac shared draft")

        // Errors from a remote command go to its result, never to the Mac's modal alert.
        let newer = await executor.execute(RemoteCommand(action: .createConversation(text: "Newer ask", agentIDs: [cedarID], attachmentIDs: [])))
        precondition(newer.outcome == .applied)
        try await waitUntil { model.comparison(newer.conversationID!)?.members.first?.anchor != nil }
        let stale = await executor.execute(RemoteCommand(action: .sendShared(conversationID: first, text: "Older thread", agentIDs: [], attachmentIDs: [])))
        precondition(stale.outcome == .rejected && stale.message?.contains("newer comparison") == true, "\(stale)")
        precondition(model.error == nil, "The Mac alert stays clear for remote failures")
        precondition(!model.comparison(first)!.followUps.contains { $0.text == "Older thread" && $0.states.values.contains(.submitted) })
        // The same failure from the Mac UI still raises the alert.
        model.state.comparisons[model.index(first)!].allDraft = "Older thread from the Mac"
        await model.followUp(first)
        precondition(model.error?.contains("newer comparison") == true)
        model.error = nil

        // A website agent through the lifted shared send, with the Mac draft intact.
        model.webAgents.setEnabled(true, for: .claude)
        let claude = model.webAgents.session(for: .claude)!
        try await waitUntil { claude.snapshot.ready }
        await model.remoteAvailabilityProbe(slow: false)
        // The Mac workspace is on another conversation, so the first send only prepares the
        // new chat page and, exactly as from the Mac composer, needs another explicit send.
        let website = RemoteAction.createConversation(text: "Website and Messages", agentIDs: ["claude", RemoteAgentIDs.messages(lumen.id)], attachmentIDs: [])
        let prepared = await executor.execute(RemoteCommand(action: website))
        precondition(prepared.code == .preparedNotSent && claude.state.attempts.isEmpty, "\(prepared)")
        let shared = await executor.execute(RemoteCommand(action: website))
        precondition(shared.outcome == .applied, "\(shared)")
        precondition(shared.agentStatuses["claude"]?.isUnresolved == false && shared.agentStatuses["claude"] != .notSent, "\(shared.agentStatuses)")
        precondition(model.comparison(shared.conversationID!)?.resolvedWebAgentIDs == [.claude])
        precondition(!model.webBroadcastBusy)
        // The website send switches the Mac workspace to the new conversation, as any send does;
        // the Mac's composer text stays saved for the workspace it was typed in.
        precondition(model.state.draft == macDraft || model.state.workspaceDrafts?.values.contains(macDraft) == true)
        // A repeated identical website ask is refused by the existing duplicate guard, not resent.
        let again = await executor.execute(RemoteCommand(action: .sendPrivate(conversationID: shared.conversationID, agentID: "claude", text: "Website and Messages", attachmentIDs: [])))
        precondition(claude.state.attempts.filter { $0.text == "Website and Messages" }.count <= 2, "\(again)")

        // Guards: a locked Mac and the iMessage setting.
        power.simulate(locked: true)
        let locked = await executor.execute(RemoteCommand(action: .createConversation(text: "Locked", agentIDs: ["claude"], attachmentIDs: [])))
        precondition(locked.code == .macLocked)
        power.simulate(locked: false)
        settings.value.allowMessagesSends = false
        let off = await executor.execute(RemoteCommand(action: .createConversation(text: "Off", agentIDs: [cedarID], attachmentIDs: [])))
        precondition(off.code == .messagesSendsOff)
        precondition(keepAwake.held == false, "Send assertions are released")
        host.discardStagedAttachments()
        try await runRemoteServiceChecks(model)
        print("PASS: remote commands run through the actual AppModel send paths (Messages new/private/shared with a staged file, website shared send that, like the Mac composer, first prepares the chat and needs a second explicit send), replay without resending, keep the Mac's drafts and files, route failures to the command result instead of the alert, and refuse when locked or when iMessage sends are off; the real RemoteService pairs an in-memory phone with no network port, streams its snapshot and events, honors keep-awake and the iMessage setting, and forgets the phone. Isolated Demo profile; simulated Messages and local website fixtures only.")
    }

    /// The real RemoteService in Demo: settings saved in the isolated profile, no network
    /// port, a phone paired over memory through the same server, projection and executor.
    @MainActor static func runRemoteServiceChecks(_ model: AppModel) async throws {
        let service = model.remote
        precondition(!service.settings.enabled && !service.running, "Remote control starts off")
        service.setEnabled(true)
        try await waitUntil { service.running }
        precondition(service.listener == nil, "The Demo app opens no port unless asked")
        precondition(FileManager.default.fileExists(atPath: model.local.url.deletingLastPathComponent().appendingPathComponent("remote-settings.json").path))
        let offer = try service.showPairingCode()
        try await renderRemoteSettings(service, name: "remote-settings-pairing")
        let connection = service.connectInMemory()!
        let phoneKey = P256.Signing.PrivateKey()
        let driver = RemoteClientDriver(mode: .pair(offer: offer, deviceName: "Fixture iPhone", deviceKey: phoneKey))
        var events: [RemoteClientDriver.Event] = []
        connection.onReceive = { bytes in
            let (outgoing, received) = try! driver.receive(bytes)
            events += received
            outgoing.forEach(connection.send)
        }
        connection.send(try driver.start())
        try await waitUntil { events.contains { if case .snapshot = $0 { true } else { false } } }
        let snapshot = events.compactMap { if case .snapshot(let s) = $0 { s } else { nil } }.first!
        precondition(snapshot.macStatus.variant == .demo && !snapshot.macStatus.locked)
        precondition(snapshot.conversations.count == model.state.comparisons.count, "Every conversation is projected")
        precondition(snapshot.agents.contains { $0.agentID == "claude" && $0.form == .website })
        precondition(snapshot.agents.contains { $0.form == .messages })
        precondition(snapshot.turns.contains { $0.text == "Remote ask" && $0.origin == .sharedPrompt })
        precondition(service.connectedDeviceID != nil && service.pairing.device?.name == "Fixture iPhone")
        precondition(service.keepAwake.held == false, "Keep-awake waits for the phone's request")
        connection.send(try driver.frame(.command(RemoteCommand(action: .setKeepAwake(enabled: true)))))
        try await waitUntil { service.keepAwake.held }
        let before = events.count
        connection.send(try driver.frame(.command(RemoteCommand(action: .createConversation(text: "From the in-memory phone", agentIDs: [RemoteAgentIDs.messages(model.state.agents[2].id)], attachmentIDs: [])))))
        try await waitUntil { events.dropFirst(before).contains { if case .commandResult(let r) = $0 { r.outcome == .rejected } else { false } } }
        let refused = events.dropFirst(before).compactMap { if case .commandResult(let r) = $0 { r } else { nil } }.last!
        precondition(refused.code == .messagesSendsOff, "The saved setting keeps iMessage sends off: \(refused)")
        service.setAllowMessagesSends(true)
        connection.send(try driver.frame(.command(RemoteCommand(action: .createConversation(text: "From the in-memory phone", agentIDs: [RemoteAgentIDs.messages(model.state.agents[2].id)], attachmentIDs: [])))))
        try await waitUntil { events.contains { if case .events(let list, _) = $0 { list.contains { if case .turnUpsert(let t) = $0.change { t.text == "From the in-memory phone" } else { false } } } else { false } } }
        try await renderRemoteSettings(service, name: "remote-settings-connected")
        service.setKeepAwake(false)
        precondition(!service.keepAwake.held, "The Mac setting turns keep-awake off")
        service.forget()
        try await waitUntil { service.connectedDeviceID == nil }
        precondition(service.pairing.device == nil)
        service.setEnabled(false)
        precondition(!service.running)
    }

    /// Optional evidence: renders the actual Settings → Remote section off-screen when
    /// MSGBLAST_REMOTE_EVIDENCE_DIR is set. Demo fixture state only.
    @MainActor static func renderRemoteSettings(_ service: RemoteService, name: String) async throws {
        guard let directory = ProcessInfo.processInfo.environment["MSGBLAST_REMOTE_EVIDENCE_DIR"] else { return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: Form { Section("Remote") { RemoteSettingsView(service: service) } }.formStyle(.grouped).frame(width: 640, height: 760))
        window.orderBack(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(for: .milliseconds(600))
        guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
    }
}
