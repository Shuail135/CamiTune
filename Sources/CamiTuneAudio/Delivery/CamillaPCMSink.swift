import Foundation
import Darwin

package protocol PCMOutputSink: AnyObject, Sendable {
    /// Process and deliver incrementally when the hardware has a small runway.
    var processingBlockFrames: Int? { get }
    func write(_ bytes: Data) throws
    func cancel()
    func finish()
}
package extension PCMOutputSink {
    var processingBlockFrames: Int? { nil }
    func cancel() {}
}

/// One PCM writer owns this sink from its first write through finish().
/// The engine manager retains its original descriptor. A bounded join may return
/// while a write is blocked, but must never close this worker's duplicate.
package final class CamillaPCMSink: PCMOutputSink, @unchecked Sendable {
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

    /// Preparation only, before this sink is handed to a PCM writer. A failed
    /// candidate must not hang behind a full stdin pipe. Restore descriptor
    /// flags before normal delivery; production writes keep their existing path.
    package func writeForPreparation(_ bytes: Data, deadline: PerformanceTick) throws {
        guard let handle else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EBADF)) }
        let fd = handle.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { _ = fcntl(fd, F_SETFL, flags) }
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                guard PerformanceClock.now() < deadline else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(ETIMEDOUT))
                }
                let written = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if written > 0 { offset += written; continue }
                if written < 0, errno == EINTR { continue }
                if written < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    _ = Darwin.poll(&descriptor, 1, 5)
                    continue
                }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(written == 0 ? EPIPE : errno))
            }
        }
    }

    /// Idempotent, called by the owning worker after its last write.
    package func finish() {
        let retired = handle
        handle = nil
        try? retired?.close()
    }
}
