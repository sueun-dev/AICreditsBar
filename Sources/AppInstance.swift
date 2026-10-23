import Foundation

/// An advisory lock held for the app's lifetime closes the startup race between
/// a login item and a simultaneous manual launch. The empty lock file stays in
/// place: removing it on exit could let two processes lock different inodes.
final class AppInstance {
    private let descriptor: Int32

    static func acquire(at path: String) throws -> AppInstance? {
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let error = errno
            close(descriptor)
            if error == EWOULDBLOCK { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
        }
        return AppInstance(descriptor: descriptor)
    }

    private init(descriptor: Int32) { self.descriptor = descriptor }
    deinit { close(descriptor) }
}
