import Foundation
import msgblastCore
import msgblastRemoteProtocol

/// Runs outside agents' sends through the iPhone controller's command executor and the
/// Mac's own send paths, so they get every duplicate-send guard and are never retried.
/// It keeps its own queue: while the phone or the Mac UI is sending, an agent's send is
/// refused as "Mac busy" rather than waiting behind it.
///
/// Full access is what allows an agent to message Messages contacts, so the phone's
/// "Send iMessages from the phone" setting does not apply here.
@MainActor final class AgentControlSends {
    let executor: RemoteCommandExecutor
    private let host: AppRemoteHost
    private let availability: AvailabilityModel

    init(model: AppModel) {
        let remote = model.remote
        // AppRemoteHost reads settings only on the main actor.
        let settings = { () -> RemoteSettings in
            var settings = MainActor.assumeIsolated { remote.settings }
            settings.allowMessagesSends = true
            return settings
        }
        let availability = AvailabilityModel(sessions: { [unowned model] in model.webAgents.sessions },
                                             inputs: { [unowned model] in model.remoteAvailabilityInputs(settings: settings()) })
        self.availability = availability
        host = AppRemoteHost(model: model, availability: availability, avatars: remote.avatars, keepAwake: remote.keepAwake, power: remote.power, settings: settings)
        executor = RemoteCommandExecutor(host: host)
    }
}

extension AppModel {
    func controlSend(_ command: RemoteCommand) async -> RemoteCommandResult { await agentSends.executor.execute(command) }
    func controlSendStatus(_ id: UUID) -> RemoteCommandResult { agentSends.executor.status(of: id) }
}
