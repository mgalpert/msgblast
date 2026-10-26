import CryptoKit
import Darwin
import Foundation
import Network
import msgblastRemoteProtocol

// msgblast-remote: pair with a Mac, print its snapshot, stream events, send one command.
// It speaks the same protocol module as the app and pins the Mac's TLS key from the QR link.

struct ClientState: Codable {
    var macName: String
    var deviceID: UUID
    var deviceKey: Data
    var macIdentityKey: Data
    var host: String
    var port: UInt16
    var spkiSHA256: Data
    var sinceSeq: UInt64?
}

let usage = """
usage:
  msgblast-remote pair '<msgblast://pair?offer=…>' [--name NAME] [--host HOST] [--state FILE] [--once] [--json]
  msgblast-remote watch [--state FILE] [--once] [--json]
  msgblast-remote agents [--state FILE]
  msgblast-remote send --to AGENT[,AGENT…] [--conversation UUID] [--private] [--state FILE] TEXT…
  msgblast-remote end --conversation UUID [--state FILE]
  msgblast-remote acknowledge --to AGENT [--attempt ID] [--state FILE]
  msgblast-remote keep-awake on|off [--state FILE]

Defaults: --state ~/Library/Application Support/msgblast-remote-client/state.json (0600, folder 0700). --once exits after the snapshot.
The client never retries a send: a lost connection reports the command as unconfirmed.
"""

var arguments = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    let value = arguments[index + 1]
    arguments.removeSubrange(index...index + 1)
    return value
}
func flag(_ name: String) -> Bool {
    guard let index = arguments.firstIndex(of: name) else { return false }
    arguments.remove(at: index)
    return true
}
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

guard let verb = arguments.first else { fail(usage) }
arguments.removeFirst()
let defaultStateDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/msgblast-remote-client", isDirectory: true)
let statePath = option("--state").map { URL(fileURLWithPath: $0) } ?? defaultStateDirectory.appendingPathComponent("state.json")
let once = flag("--once"), json = flag("--json")

func loadState() -> ClientState {
    guard let data = try? Data(contentsOf: statePath), let state = try? JSONDecoder().decode(ClientState.self, from: data) else {
        fail("No paired state at \(statePath.path). Run `msgblast-remote pair '<link>'` first.")
    }
    return state
}
func saveState(_ state: ClientState) {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(state) else { return }
    let directory = statePath.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    if directory == defaultStateDirectory { chmod(directory.path, 0o700) }
    // Owner-only: the file holds the client's private device key.
    FileManager.default.createFile(atPath: statePath.path, contents: data, attributes: [.posixPermissions: 0o600])
    chmod(statePath.path, 0o600)
}

func describe(_ availability: AgentAvailability) -> String {
    let reasons = availability.reasons.map { "\($0.code.rawValue)\($0.permission.map { "(\($0.rawValue))" } ?? "") [fix on \($0.fixOn.rawValue)]: \($0.userText)" }
    let detail: String
    if case .busy(let text) = availability.readiness { detail = " – \(text)" } else { detail = "" }
    return "  \(availability.agentID) · \(availability.formLabel) · \(availability.readiness.state)\(detail)\(availability.visibleInGrid ? "" : " · hidden")" +
        (reasons.isEmpty ? "" : "\n" + reasons.map { "      \($0)" }.joined(separator: "\n"))
}

func printJSON<T: Encodable>(_ value: T) {
    let encoder = RemoteProtocol.encoder(); encoder.outputFormatting = [.sortedKeys]
    if let data = try? encoder.encode(value) { print(String(decoding: data, as: UTF8.self)) }
}

final class Session: @unchecked Sendable {
    let driver: RemoteClientDriver
    let connection: NWConnection
    var state: ClientState?
    var pendingCommand: RemoteCommand?
    var onAuthenticated: ((Session) -> Void)?
    var snapshotSeen = false
    let pairingOffer: RemotePairingOffer?

    init(host: String, port: UInt16, spki: Data, mode: RemoteClientDriver.Mode, sinceSeq: UInt64?, offer: RemotePairingOffer?) {
        driver = RemoteClientDriver(mode: mode, sinceSeq: sinceSeq)
        pairingOffer = offer
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            let reference = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let leaf = (SecTrustCopyCertificateChain(reference) as? [SecCertificate])?.first, let key = SecCertificateCopyKey(leaf),
                  let x963 = SecKeyCopyExternalRepresentation(key, nil) as Data? else { complete(false); return }
            complete(RemoteTLSPin.spkiSHA256(p256X963: x963) == spki)
        }, .main)
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: NWParameters(tls: tls))
    }

    func start() {
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                send(try! driver.start())
                read()
            case .failed(let error): fail("Connection failed: \(error). Check the Mac's address, that remote control is on, and that the TLS key matches the QR code.")
            case .waiting(let error): fail("Cannot reach the Mac: \(error)")
            default: break
            }
        }
        connection.start(queue: .main)
    }
    func send(_ data: Data) { connection.send(content: data, completion: .contentProcessed { _ in }) }
    func send(_ message: RemoteMessage) { send(try! driver.frame(message)) }
    func read() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [self] data, _, complete, error in
            if let data, !data.isEmpty {
                do {
                    let (outgoing, events) = try driver.receive(data)
                    outgoing.forEach(send)
                    events.forEach(handle)
                } catch { fail("Protocol error: \(error)") }
            }
            if complete || error != nil {
                if let pendingCommand { fail("Disconnected before the Mac confirmed command \(pendingCommand.clientCommandID). Check the Mac; nothing will be resent.") }
                fail("The Mac closed the connection.")
            }
            read()
        }
    }

    func handle(_ event: RemoteClientDriver.Event) {
        switch event {
        case .paired(let complete, let macKey):
            guard let offer = pairingOffer, case .pair(_, _, let key) = modeKey else { return }
            state = ClientState(macName: complete.macName, deviceID: complete.deviceID, deviceKey: (key as! P256.Signing.PrivateKey).rawRepresentation,
                                macIdentityKey: macKey, host: chosenHost, port: offer.port, spkiSHA256: offer.spkiSHA256, sinceSeq: nil)
            saveState(state!)
            print("Paired with \(complete.macName) as device \(complete.deviceID). State saved to \(statePath.path).")
            onAuthenticated?(self)
        case .authenticated(let id):
            print("Connected to \(state?.macName ?? "Mac") as \(id).")
            onAuthenticated?(self)
        case .snapshot(let snapshot):
            if json { printJSON(snapshot) } else {
                if snapshot.partIndex == 0 {
                    let status = snapshot.macStatus
                    print("Snapshot seq \(snapshot.seq) · \(status.macName) (\(status.variant.rawValue)) · \(status.locked ? "LOCKED" : "unlocked") · \(status.awake ? "awake" : "asleep") · keep-awake \(status.keepAwakeHeld ? "held" : "not held") · iMessage sends \(status.messagesSendsAllowed ? "on" : "off")")
                    print("Agents (\(snapshot.agents.count)), grid: \(snapshot.grid.visibleAgentIDs.joined(separator: ", "))")
                    snapshot.agents.forEach { print(describe($0)) }
                    print("Conversations (\(snapshot.conversations.count)):")
                    for conversation in snapshot.conversations.prefix(20) {
                        print("  \(conversation.id) · \(conversation.title) · \(conversation.agentIDs.count) agents · \(conversation.endedAt == nil ? "active" : "ended")\(conversation.canEnd ? "" : " · end needs Mac") · unresolved \(conversation.unresolvedAttemptCount)")
                    }
                }
                print("Turns in part \(snapshot.partIndex + 1)/\(snapshot.partCount): \(snapshot.turns.count) · attempts: \(snapshot.attempts.count)")
            }
            if snapshot.partIndex == snapshot.partCount - 1 {
                snapshotSeen = true
                persistSeq()
                if once && pendingCommand == nil { exit(0) }
            }
        case .events(let events, let latest):
            for event in events {
                if json { printJSON(event); continue }
                switch event.change {
                case .turnUpsert(let turn): print("[\(event.seq)] turn \(turn.agentID ?? "you") \(turn.role.rawValue): \(turn.text.prefix(160))")
                case .attemptUpsert(let attempt): print("[\(event.seq)] attempt \(attempt.agentID) → \(attempt.status.rawValue)\(attempt.detail.map { " (\($0))" } ?? "")")
                case .agentUpsert(let agent): print("[\(event.seq)] agent\n" + describe(agent))
                case .macStatus(let status): print("[\(event.seq)] Mac \(status.locked ? "locked" : "unlocked"), \(status.awake ? "awake" : "asleep"), keep-awake \(status.keepAwakeHeld ? "held" : "not held"), sending \(status.sendingAgentIDs)")
                case .conversationUpsert(let conversation): print("[\(event.seq)] conversation \(conversation.id) \(conversation.title)")
                default: print("[\(event.seq)] \(event.change.kind)")
                }
            }
            driver.sinceSeq = latest
            persistSeq()
            if events.isEmpty && !json { print("Up to date at seq \(latest).") }
            // A resumed session starts with the missed events (possibly none).
            if once && pendingCommand == nil && !snapshotSeen { exit(0) }
        case .commandResult(let result):
            if json { printJSON(result) } else {
                print("Command \(result.clientCommandID): \(result.outcome.rawValue)\(result.code.map { " [\($0.rawValue)]" } ?? "")\(result.replayed ? " (replayed)" : "")\(result.message.map { " – \($0)" } ?? "")")
                if let id = result.conversationID { print("  conversation \(id)") }
                for (agent, status) in result.agentStatuses.sorted(by: { $0.key < $1.key }) { print("  \(agent): \(status.rawValue)") }
                if let id = result.attachmentID { print("  attachment \(id)") }
            }
            if result.outcome != .accepted, result.clientCommandID == pendingCommand?.clientCommandID { exit(result.outcome == .applied ? 0 : 2) }
        case .pong(let nonce, let seq): print("pong \(nonce) seq \(seq)")
        case .error(let error):
            print("Mac says \(error.code.rawValue): \(error.message)")
            if error.code != .macLocked { exit(3) }
        }
    }
    var modeKey: RemoteClientDriver.Mode!
    var chosenHost = ""
    func persistSeq() {
        guard var state else { return }
        state.sinceSeq = driver.sinceSeq
        self.state = state
        saveState(state)
    }
}

func command(for verb: String) -> RemoteCommand? {
    switch verb {
    case "send":
        guard let to = option("--to") else { fail("send needs --to AGENT") }
        let conversation = option("--conversation").map { UUID(uuidString: $0) ?? { fail("Bad conversation id") }() }
        let isPrivate = flag("--private")
        let text = arguments.joined(separator: " ")
        let agents = to.split(separator: ",").map(String.init)
        if isPrivate { return RemoteCommand(action: .sendPrivate(conversationID: conversation, agentID: agents[0], text: text, attachmentIDs: [])) }
        if let conversation { return RemoteCommand(action: .sendShared(conversationID: conversation, text: text, agentIDs: agents, attachmentIDs: [])) }
        return RemoteCommand(action: .createConversation(text: text, agentIDs: agents, attachmentIDs: []))
    case "end":
        guard let id = option("--conversation").flatMap(UUID.init(uuidString:)) else { fail("end needs --conversation UUID") }
        return RemoteCommand(action: .endConversation(conversationID: id))
    case "acknowledge":
        guard let agent = option("--to") else { fail("acknowledge needs --to AGENT") }
        return RemoteCommand(action: .acknowledgeIncomplete(agentID: agent, attemptID: option("--attempt")))
    case "keep-awake":
        return RemoteCommand(action: .setKeepAwake(enabled: arguments.first != "off"))
    default: return nil
    }
}

let session: Session
switch verb {
case "pair":
    guard let link = arguments.first, let url = URL(string: link), let offer = try? RemotePairingOffer(url: url) else { fail("pair needs the msgblast://pair link from Settings → Remote.\n\n" + usage) }
    arguments.removeFirst()
    let name = option("--name") ?? Host.current().localizedName.map { "\($0) (remote client)" } ?? "Remote client"
    guard let host = option("--host") ?? offer.endpoints.first?.host else { fail("The pairing link has no address. Pass --host.") }
    guard offer.expiresAt > Date() else { fail("The pairing code expired. Show a new one on the Mac.") }
    let key = P256.Signing.PrivateKey()
    let mode = RemoteClientDriver.Mode.pair(offer: offer, deviceName: name, deviceKey: key)
    session = Session(host: host, port: offer.port, spki: offer.spkiSHA256, mode: mode, sinceSeq: nil, offer: offer)
    session.modeKey = mode
    session.chosenHost = host
case "watch", "agents", "send", "end", "acknowledge", "keep-awake":
    let state = loadState()
    guard let key = try? P256.Signing.PrivateKey(rawRepresentation: state.deviceKey) else { fail("The saved device key is unreadable.") }
    let mode = RemoteClientDriver.Mode.resume(deviceID: state.deviceID, deviceKey: key, macIdentityKey: state.macIdentityKey)
    // Commands want a fresh view; watch resumes from the saved cursor.
    session = Session(host: option("--host") ?? state.host, port: state.port, spki: state.spkiSHA256, mode: mode, sinceSeq: verb == "watch" ? state.sinceSeq : nil, offer: nil)
    session.state = state
    session.modeKey = mode
    if let command = command(for: verb) {
        session.pendingCommand = command
        session.onAuthenticated = { session in
            print("Sending \(command.action.kind) as \(command.clientCommandID)")
            session.send(.command(command))
        }
    } else if verb == "agents" {
        session.onAuthenticated = { _ in }
    }
default:
    fail(usage)
}
session.start()
signal(SIGINT) { _ in exit(130) }
dispatchMain()
