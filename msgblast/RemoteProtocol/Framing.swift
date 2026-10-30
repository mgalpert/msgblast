import Foundation

/// Length-prefixed frames: a 4-byte big-endian payload length, then the payload.
/// Symmetric on both ends; independent of the route (TLS stream, relay, in memory).
public enum RemoteFraming {
    public static let headerBytes = 4
    public static func frame(_ payload: Data, maximum: Int = RemoteProtocol.maximumFrameBytes) throws -> Data {
        guard !payload.isEmpty else { throw RemoteProtocolError.emptyFrame }
        guard payload.count <= maximum else { throw RemoteProtocolError.frameTooLarge(payload.count) }
        var length = UInt32(payload.count).bigEndian
        var out = Data(bytes: &length, count: headerBytes)
        out.append(payload)
        return out
    }
}

/// Accumulates stream bytes and yields complete frames. A length prefix above the
/// maximum fails immediately, before any payload is buffered.
public struct RemoteFrameDecoder: Sendable {
    public let maximum: Int
    private var buffer = Data()
    public init(maximum: Int = RemoteProtocol.maximumFrameBytes) { self.maximum = maximum }
    public var bufferedByteCount: Int { buffer.count }
    public mutating func append(_ bytes: Data) throws -> [Data] {
        buffer.append(bytes)
        var frames: [Data] = []
        while buffer.count >= RemoteFraming.headerBytes {
            let start = buffer.startIndex
            let length = buffer[start..<start + RemoteFraming.headerBytes].reduce(0) { ($0 << 8) | Int($1) }
            guard length > 0 else { throw RemoteProtocolError.emptyFrame }
            guard length <= maximum else { throw RemoteProtocolError.frameTooLarge(length) }
            guard buffer.count >= RemoteFraming.headerBytes + length else { break }
            frames.append(Data(buffer[start + RemoteFraming.headerBytes ..< start + RemoteFraming.headerBytes + length]))
            buffer = Data(buffer[(start + RemoteFraming.headerBytes + length)...])
        }
        return frames
    }
}
