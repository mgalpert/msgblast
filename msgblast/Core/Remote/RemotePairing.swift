import Combine
import CryptoKit
import Foundation
import msgblastRemoteProtocol

/// The one phone paired with this Mac (v1: exactly one). Only its public key,
/// name and dates are stored; no transcript or credential is.
public struct RemotePairedDevice: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var publicKey: Data
    public var created: Date
    public var lastSeen: Date?
    public init(id: UUID = UUID(), name: String, publicKey: Data, created: Date, lastSeen: Date? = nil) {
        self.id = id; self.name = name; self.publicKey = publicKey; self.created = created; self.lastSeen = lastSeen
    }
}

public enum RemotePairingFailure: LocalizedError, Equatable {
    case replacementNeedsConfirmation(String)
    case noOffer, expired, tooManyAttempts, invalidProof, invalidDevice
    case storage(String)
    public var errorDescription: String? {
        switch self {
        case .replacementNeedsConfirmation(let name): "\(name) is paired with this Mac. Confirm on the Mac to replace it."
        case .noOffer: "Pairing is not open on this Mac. Show a new code in Settings → Remote."
        case .expired: "The pairing code expired. Show a new code on the Mac."
        case .tooManyAttempts: "Too many wrong pairing attempts. Show a new code on the Mac."
        case .invalidProof: "The pairing code did not match."
        case .invalidDevice: "The phone's identity could not be verified."
        case .storage(let message): message
        }
    }
    var errorCode: RemoteErrorMessage.Code {
        switch self {
        case .replacementNeedsConfirmation: .pairingReplaceNeedsConfirmation
        case .noOffer, .expired, .tooManyAttempts: .pairingClosed
        case .invalidProof, .invalidDevice, .storage: .pairingFailed
        }
    }
}

/// Pairing state: a short-lived one-time offer (the QR code) and the persisted
/// device record `remote-device.json` (0600) in the support folder.
@MainActor
public final class RemotePairing: ObservableObject {
    public static let maximumFailedAttempts = 5
    @Published public private(set) var device: RemotePairedDevice?
    @Published public private(set) var offer: RemotePairingOffer?
    @Published public private(set) var loadError: String?
    public let url: URL
    private let now: () -> Date
    private var offerAllowsReplacement = false
    private var failedAttempts = 0

    public init(directory: URL, now: @escaping () -> Date = Date.init) {
        url = directory.appendingPathComponent("remote-device.json")
        self.now = now
        do {
            if let data = try RemotePrivateFile.read(url) {
                device = try JSONDecoder().decode(RemotePairedDevice.self, from: data)
            }
        } catch {
            // Keep the unreadable file; pairing stays closed until the user chooses Forget.
            loadError = (error as? LocalizedError)?.errorDescription ?? RemoteStorageError.invalid(url.lastPathComponent).errorDescription
        }
    }

    public var isOfferValid: Bool { offer.map { $0.expiresAt > now() } ?? false }

    /// Opens pairing for `RemoteProtocol.pairingCodeLifetime`. Replacing the paired phone
    /// requires `confirmReplacement`, which only the Mac UI passes after asking.
    @discardableResult
    public func openOffer(macName: String, variant: MacVariant, endpoints: [RemoteEndpoint], port: UInt16,
                          identity: RemoteIdentity, confirmReplacement: Bool = false) throws -> RemotePairingOffer {
        if let loadError { throw RemotePairingFailure.storage(loadError) }
        if let device, !confirmReplacement { throw RemotePairingFailure.replacementNeedsConfirmation(device.name) }
        let offer = RemotePairingOffer(macName: macName, variant: variant, endpoints: endpoints, port: port, spkiSHA256: identity.spkiSHA256,
                                       identityKeySHA256: identity.identityKeySHA256, code: RemotePairingOffer.makeCode(),
                                       expiresAt: now().addingTimeInterval(RemoteProtocol.pairingCodeLifetime))
        self.offer = offer
        offerAllowsReplacement = confirmReplacement
        failedAttempts = 0
        return offer
    }

    public func closeOffer() { offer = nil; offerAllowsReplacement = false; failedAttempts = 0 }

    /// Verifies the phone's answer to `challenge` within the session `transcript`. Success
    /// consumes the offer and saves the device (replacing the previous one only when confirmed).
    public func complete(_ response: RemotePairResponse, challenge: Data, transcript: Data) -> Result<RemotePairedDevice, RemotePairingFailure> {
        guard let offer else { return .failure(.noOffer) }
        guard offer.expiresAt > now() else { closeOffer(); return .failure(.expired) }
        guard failedAttempts < Self.maximumFailedAttempts else { closeOffer(); return .failure(.tooManyAttempts) }
        let expected = RemoteHandshake.pairingProof(code: offer.code, challenge: challenge, transcript: transcript, devicePublicKey: response.devicePublicKey)
        guard Self.constantTimeEqual(expected, response.proof) else {
            failedAttempts += 1
            if failedAttempts >= Self.maximumFailedAttempts { closeOffer() }
            return .failure(.invalidProof)
        }
        guard (try? P256.Signing.PublicKey(x963Representation: response.devicePublicKey)) != nil,
              RemoteHandshake.verify(signature: response.signature, over: RemoteHandshake.pairingSignedData(transcript: transcript, challenge: challenge), publicKey: response.devicePublicKey) else {
            failedAttempts += 1
            return .failure(.invalidDevice)
        }
        if device != nil && !offerAllowsReplacement { return .failure(.replacementNeedsConfirmation(device!.name)) }
        let name = String(response.deviceName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        let paired = RemotePairedDevice(name: name.isEmpty ? "Phone" : name, publicKey: response.devicePublicKey, created: now(), lastSeen: now())
        do { try save(paired) } catch { return .failure(.storage((error as? LocalizedError)?.errorDescription ?? "The paired phone could not be saved.")) }
        device = paired
        closeOffer()
        return .success(paired)
    }

    /// A resuming phone proves it holds the paired key by signing this session's transcript.
    public func verify(_ authenticate: RemoteAuthenticate, transcript: Data) -> RemotePairedDevice? {
        guard let device, device.id == authenticate.deviceID,
              RemoteHandshake.verify(signature: authenticate.signature, over: transcript, publicKey: device.publicKey) else { return nil }
        return device
    }

    public func markSeen() {
        guard var updated = device else { return }
        updated.lastSeen = now()
        if (try? save(updated)) != nil { device = updated }
    }

    /// Removes the paired phone (or an unreadable record the user chose to discard).
    public func forget() throws {
        try RemotePrivateFile.remove(url)
        device = nil
        loadError = nil
        closeOffer()
    }

    private func save(_ device: RemotePairedDevice) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try RemotePrivateFile.write(try encoder.encode(device), to: url)
    }

    static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
