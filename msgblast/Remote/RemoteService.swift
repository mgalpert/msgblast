import Combine
import Foundation
import msgblastCore
import msgblastRemoteProtocol

/// Remote control for one paired phone: settings, identity, pairing, listener,
/// projection, availability and command execution. Off until the user turns it on.
/// The Demo app serves the same protocol over memory and opens a port only when asked.
@MainActor
final class RemoteService: ObservableObject {
    @Published private(set) var settings: RemoteSettings
    @Published private(set) var problem: String?
    @Published private(set) var running = false
    @Published private(set) var identityStorage: RemoteIdentityStorage?
    /// Demo only: also listen on the network (for the command-line harness). Not saved.
    @Published private(set) var demoNetworkAllowed: Bool
    let pairing: RemotePairing
    let keepAwake: RemoteKeepAwake
    let power: MacPowerState
    let availability: AvailabilityModel
    private(set) var server: RemoteServer?
    private(set) var listener: RemoteListener?
    private var projection: RemoteProjection?
    private var host: AppRemoteHost?
    private var identity: RemoteIdentity?
    private unowned let model: AppModel
    private let directory: URL
    private var subscriptions: Set<AnyCancellable> = []

    init(model: AppModel) {
        self.model = model
        directory = model.local.url.deletingLastPathComponent()
        let (loaded, error) = RemoteSettings.load(directory: directory)
        settings = loaded
        problem = error
        demoNetworkAllowed = model.demo && ProcessInfo.processInfo.arguments.contains("--remote-listen")
        pairing = RemotePairing(directory: directory)
        keepAwake = RemoteKeepAwake(settingEnabled: loaded.keepAwake)
        power = MacPowerState()
        let settingsBox = SettingsReader()
        availability = AvailabilityModel(sessions: { [unowned model] in model.webAgents.sessions },
                                         inputs: { [unowned model] in model.remoteAvailabilityInputs(settings: settingsBox.value) },
                                         probe: { [unowned model] slow in await model.remoteAvailabilityProbe(slow: slow) })
        settingsReader = settingsBox
        settingsBox.value = loaded
        power.$locked.removeDuplicates().dropFirst().sink { [weak self] _ in
            Task { @MainActor in self?.projection?.refreshNow(); self?.server?.lockStateChanged() }
        }.store(in: &subscriptions)
        keepAwake.$held.removeDuplicates().dropFirst().sink { [weak self] _ in
            Task { @MainActor in self?.projection?.schedule() }
        }.store(in: &subscriptions)
        if settings.enabled { Task { await start() } }
    }

    private final class SettingsReader { var value = RemoteSettings() }
    private let settingsReader: SettingsReader

    var macName: String { Host.current().localizedName ?? "Mac" }
    var variant: MacVariant { model.remoteMacStatus(settings: settings, power: power, keepAwake: keepAwake).variant }
    var connectedDeviceID: UUID? { server?.connectedDeviceID }
    var endpoints: [RemoteEndpoint] { listener?.endpoints ?? [] }
    var port: UInt16? { listener?.port }
    var listenerError: String? { listener?.error }

    private func update(_ edit: (inout RemoteSettings) -> Void) {
        var next = settings
        edit(&next)
        guard next != settings else { return }
        do { try next.save(directory: directory); problem = nil }
        catch { problem = error.localizedDescription; return }
        settings = next
        settingsReader.value = next
        keepAwake.setSettingEnabled(next.keepAwake)
        projection?.schedule()
    }

    func setEnabled(_ enabled: Bool) {
        update { $0.enabled = enabled }
        if enabled { Task { await start() } } else { stop() }
    }
    func setBindPolicy(_ policy: RemoteBindPolicy) {
        update { $0.bindPolicy = policy }
        if running { Task { await startListener() } }
    }
    func setKeepAwake(_ enabled: Bool) { update { $0.keepAwake = enabled } }
    func setAllowMessagesSends(_ allowed: Bool) { update { $0.allowMessagesSends = allowed }; availability.recompute() }
    func setDemoNetworkAllowed(_ allowed: Bool) {
        guard model.demo else { return }
        demoNetworkAllowed = allowed
        if running { Task { await startListener() } }
    }

    func start() async {
        guard settings.enabled, server == nil else { return }
        do {
            let identity = try RemoteIdentityStore(directory: directory).loadOrCreate()
            self.identity = identity
            identityStorage = identity.storage
            let host = AppRemoteHost(model: model, availability: availability, keepAwake: keepAwake, power: power, settings: { [settingsReader] in settingsReader.value })
            let executor = RemoteCommandExecutor(host: host)
            let journal = RemoteChangeJournal()
            let model = model, power = power, keepAwake = keepAwake, availability = availability, reader = settingsReader
            let triggers: [AnyPublisher<Void, Never>] = [model.objectWillChange.map { _ in }.eraseToAnyPublisher(),
                model.webAgents.objectWillChange.map { _ in }.eraseToAnyPublisher(), model.personalAgent.objectWillChange.map { _ in }.eraseToAnyPublisher(),
                availability.objectWillChange.map { _ in }.eraseToAnyPublisher(), power.objectWillChange.map { _ in }.eraseToAnyPublisher()]
            let projection = RemoteProjection(journal: journal, triggers: triggers) {
                RemoteProjectionBuilder.state(from: model.remoteProjectionInput(settings: reader.value, power: power, keepAwake: keepAwake, agents: availability.recompute()))
            }
            let server = RemoteServer(identity: identity, pairing: pairing, executor: executor, journal: journal, variant: variant,
                                      macName: { [weak self] in self?.macName ?? "Mac" }, isLocked: { power.locked }, refreshJournal: { projection.refreshNow() })
            projection.onEvents = { [weak server] in server?.broadcast($0) }
            server.onClientChange = { [weak self] connected in self?.clientChanged(connected) }
            server.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
            self.host = host; self.projection = projection; self.server = server
            running = true
            problem = nil
            await startListener()
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? "Remote control could not start."
        }
    }

    private func startListener() async {
        guard let identity, let server else { return }
        if model.demo && !demoNetworkAllowed {
            listener?.shutdown(); listener = nil
            objectWillChange.send()
            return
        }
        let listener = self.listener ?? RemoteListener(identity: identity, serviceName: "msgblast on \(macName)") { [weak server] in server?.accept($0) }
        self.listener = listener
        listener.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        if let port = await listener.start(policy: settings.bindPolicy, port: settings.port), port != settings.port {
            update { $0.port = port }
        }
        objectWillChange.send()
    }

    func stop() {
        server?.disconnectAll(.serviceStopped, "Remote control was turned off on the Mac.")
        listener?.shutdown(); listener = nil
        projection?.stop(); projection = nil
        availability.stop()
        keepAwake.setClient(connected: false)
        host?.discardStagedAttachments(); host = nil
        server = nil
        pairing.closeOffer()
        running = false
    }

    private func clientChanged(_ connected: Bool) {
        keepAwake.setClient(connected: connected)
        if connected {
            projection?.start()
            availability.start()
        } else {
            projection?.stop()
            availability.stop()
            host?.discardStagedAttachments()
        }
        objectWillChange.send()
    }

    /// Opens pairing for two minutes. Replacing the paired phone needs `confirmReplacement`.
    @discardableResult
    func showPairingCode(confirmReplacement: Bool = false) throws -> RemotePairingOffer {
        guard let identity else { throw RemotePairingFailure.storage(problem ?? "Turn on remote control first.") }
        let offer = try pairing.openOffer(macName: macName, variant: variant, endpoints: endpoints, port: port ?? 0, identity: identity, confirmReplacement: confirmReplacement)
        objectWillChange.send()
        return offer
    }

    func forget() {
        server?.disconnectAll(.forgotten, "This Mac forgot the phone. Pair again to reconnect.")
        do { try pairing.forget(); problem = nil } catch { problem = error.localizedDescription }
        objectWillChange.send()
    }

    /// Demo and fixtures: a client end served by the same server, with no network port.
    func connectInMemory() -> InMemoryRemoteConnection? {
        guard let server else { return nil }
        let (serverEnd, clientEnd) = InMemoryRemoteConnection.pair()
        server.accept(serverEnd)
        return clientEnd
    }

    var statusText: String {
        if !settings.enabled { return "Off" }
        if let problem { return problem }
        if power.locked { return "Mac locked · phone shows Disconnected" }
        if let device = pairing.device, connectedDeviceID == device.id { return "\(device.name) connected" }
        if model.demo && listener == nil { return "Demo · in-memory only, no network port" }
        if let error = listenerError { return error }
        if let port, !endpoints.isEmpty { return "Listening on \(endpoints.map(\.host).joined(separator: ", ")) port \(port)" }
        return "Starting…"
    }
}
