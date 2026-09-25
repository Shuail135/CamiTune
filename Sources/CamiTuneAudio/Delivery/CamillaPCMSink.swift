import Foundation
import Darwin

/// One PCM writer owns this sink from its first write through finish().
/// The engine manager retains its original descriptor. A bounded join may return
/// while a write is blocked, but must never close this worker's duplicate.
package final class CamillaPCMSink: @unchecked Sendable {
    private var handle: FileHandle?

    package init(duplicating descriptor: Int32) throws {
        let owned = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        guard owned >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        // Broken pipes are reported as write failures, never process signals.
        guard fcntl(owned, F_SETNOSIGPIPE, 1) == 0 else {
            let failure = errno
            Darwin.close(owned)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(failure))
        }
        handle = FileHandle(fileDescriptor: owned, closeOnDealloc: true)
    }

    package func write(_ bytes: Data) throws {
        guard let handle else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EBADF)) }
        try handle.write(contentsOf: bytes)
    }

    /// Idempotent, called by the owning worker after its last write.
    package func finish() {
        let retired = handle
        handle = nil
        try? retired?.close()
    }
}
