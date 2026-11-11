import Foundation
import CryptoKit

/// Direct routes also serve TLS 1.3 from the Mac identity; the phone pins the
/// SHA-256 of the certificate's DER SubjectPublicKeyInfo (no CA, no hostname).
public enum RemoteTLSPin {
    /// DER prefix of a P-256 SubjectPublicKeyInfo (id-ecPublicKey, prime256v1, 65-byte BIT STRING).
    public static let p256SPKIPrefix: [UInt8] = [0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
                                                 0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00]
    public static func subjectPublicKeyInfo(p256X963 key: Data) -> Data { Data(p256SPKIPrefix) + key }
    public static func spkiSHA256(p256X963 key: Data) -> Data { Data(SHA256.hash(data: subjectPublicKeyInfo(p256X963: key))) }
}
