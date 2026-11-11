import Foundation
import Darwin

/// Owner-only files for remote-control state (identity, paired device, settings).
/// Reads refuse symlinks, other owners, group/other permissions, and oversize files.
enum RemotePrivateFile {
    static let maximumBytes = 256 * 1024

    static func read(_ url: URL) throws -> Data? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0, errno == ENOENT { return nil }
        guard descriptor >= 0 else { throw RemoteStorageError.unreadable(url.lastPathComponent) }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o077 == 0, info.st_size > 0, info.st_size <= maximumBytes,
              let data = try file.read(upToCount: maximumBytes + 1), data.count <= maximumBytes else {
            throw RemoteStorageError.unreadable(url.lastPathComponent)
        }
        return data
    }

    static func write(_ data: Data, to url: URL) throws {
        guard data.count <= maximumBytes else { throw RemoteStorageError.unwritable(url.lastPathComponent) }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw RemoteStorageError.unwritable(url.lastPathComponent) }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close(); unlink(temporary.path) }
        try file.write(contentsOf: data)
        guard fsync(descriptor) == 0, rename(temporary.path, url.path) == 0 else { throw RemoteStorageError.unwritable(url.lastPathComponent) }
    }

    static func remove(_ url: URL) throws {
        guard unlink(url.path) == 0 || errno == ENOENT else { throw RemoteStorageError.unwritable(url.lastPathComponent) }
    }
}

public enum RemoteStorageError: LocalizedError, Equatable {
    case unreadable(String), unwritable(String), invalid(String)
    public var errorDescription: String? {
        switch self {
        case .unreadable(let name): "Remote control data (\(name)) could not be read. It was left in place."
        case .unwritable(let name): "Remote control data (\(name)) could not be saved."
        case .invalid(let name): "Remote control data (\(name)) is not valid. It was left in place."
        }
    }
}
