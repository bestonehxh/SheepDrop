import Foundation

/// A Stop button for the transfer in flight. The UI sets it from the main
/// thread; the worker reads it between chunks on its own queue and stops with
/// `TransferCancel.error`. Each transfer clears it as it starts.
nonisolated final class TransferCancel: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false

    func request() { lock.lock(); requested = true; lock.unlock() }
    func reset() { lock.lock(); requested = false; lock.unlock() }
    var isRequested: Bool { lock.lock(); defer { lock.unlock() }; return requested }

    /// Not a lost link, not an auth failure — the session stays connected.
    static let error = SFTPError(message: "cancelled")
}
