import XCTest
import CryptoKit
import Security
@testable import msgblastCore
import msgblastRemoteProtocol

private final class MemoryKeychain: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    var client: RemoteIdentityKeychain {
        RemoteIdentityKeychain(read: { url in self.lock.withLock { self.items[url.path] } },
                               save: { data, url in self.lock.withLock { self.items[url.path] = data }; return true },
                               delete: { url in self.lock.withLock { self.items[url.path] = nil } })
    }
}

final class RemoteIdentityTests: XCTestCase {
    private func directory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("msgblast-remote-identity-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testSecureEnclaveIdentityPersistsPrivatelyAndServesTLS() throws {
        guard SecureEnclave.isAvailable else { throw XCTSkip("Hardware protection needs a Secure Enclave") }
        let folder = directory()
        let store = RemoteIdentityStore(directory: folder, keychain: .unavailable)
        let first = try store.loadOrCreate()
        XCTAssertEqual(first.storage, .secureEnclave)
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.intValue & 0o777, 0o600)
        let saved = try Data(contentsOf: store.url)
        XCTAssertNil(saved.range(of: first.signingKey.rawRepresentation), "The private key is never written in plaintext")

        let second = try store.loadOrCreate()
        XCTAssertEqual(second.publicKeyX963, first.publicKeyX963)
        XCTAssertEqual(second.certificate, first.certificate, "The certificate stays stable across launches")
        XCTAssertEqual(second.spkiSHA256, first.spkiSHA256)

        // The pinned SPKI hash is what a TLS client computes from the served certificate.
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, first.certificate as CFData))
        XCTAssertEqual(SecCertificateCopySubjectSummary(certificate) as String?, "msgblast remote")
        let key = try XCTUnwrap(SecCertificateCopyKey(certificate))
        let x963 = try XCTUnwrap(SecKeyCopyExternalRepresentation(key, nil) as Data?)
        XCTAssertEqual(RemoteTLSPin.spkiSHA256(p256X963: x963), first.spkiSHA256)
        XCTAssertNotNil(try? first.tlsIdentity())
    }

    func testKeychainFallbackAndSessionOnlyWithoutProtectedStorage() throws {
        let keychain = MemoryKeychain()
        let folder = directory()
        let stored = RemoteIdentityStore(directory: folder, secureEnclaveAvailable: false, keychain: keychain.client)
        let first = try stored.loadOrCreate()
        XCTAssertEqual(first.storage, .keychain)
        XCTAssertEqual(try stored.loadOrCreate().publicKeyX963, first.publicKeyX963)
        try stored.reset()
        XCTAssertFalse(FileManager.default.fileExists(atPath: stored.url.path))

        let session = RemoteIdentityStore(directory: directory(), secureEnclaveAvailable: false, keychain: .unavailable)
        let ephemeral = try session.loadOrCreate()
        XCTAssertEqual(ephemeral.storage, .sessionOnly)
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.url.path), "Session-only identities write nothing")
        XCTAssertNotEqual(try session.loadOrCreate().publicKeyX963, ephemeral.publicKeyX963, "Each launch gets a new session identity")
    }

    func testUnreadableIdentityIsPreservedNotReplaced() throws {
        let folder = directory()
        let store = RemoteIdentityStore(directory: folder, secureEnclaveAvailable: false, keychain: MemoryKeychain().client)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: store.url)
        chmod(store.url.path, 0o600)
        XCTAssertThrowsError(try store.loadOrCreate())
        XCTAssertEqual(try Data(contentsOf: store.url), Data("{not json".utf8))
        chmod(store.url.path, 0o644)
        XCTAssertThrowsError(try store.loadOrCreate(), "Group/other-readable identity files are refused")
    }

    func testCertificateEncodesLongLengthsAndLateDates() throws {
        XCTAssertEqual(RemoteCertificate.der(0x04, Array(repeating: 0, count: 200)).prefix(3), [0x04, 0x81, 0xC8])
        XCTAssertEqual(RemoteCertificate.der(0x04, Array(repeating: 0, count: 300)).prefix(4), [0x04, 0x82, 0x01, 0x2C])
        let late = Date(timeIntervalSince1970: 2_600_000_000) // 2052: GeneralizedTime
        XCTAssertEqual(RemoteCertificate.time(late).first, 0x18)
        let certificate = try RemoteCertificate.selfSigned(key: P256.Signing.PrivateKey(), now: late)
        XCTAssertNotNil(SecCertificateCreateWithData(nil, certificate as CFData))
    }
}
