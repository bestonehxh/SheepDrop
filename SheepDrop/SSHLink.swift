import Foundation

// One POSIX TCP connection to an SSH server, with the blocking-with-timeout
// shape the engine queue wants: connect (with timeout), read chunks
// (poll-bounded so shutdown is responsive), write all, close.
//
// Error texts deliberately carry the tokens SFTPSession.isConnectionLost
// matches on ("connection refused", "timed out", "connection reset", …) so a
// dead link flips the tab to "Not connected" instead of leaving it stuck.

nonisolated struct SSHLinkError: Error, Sendable {
    var message: String
}

nonisolated final class SSHLink: @unchecked Sendable {
    private var fd: Int32 = -1

    /// Opens the TCP connection. `timeoutMS` bounds DNS + connect together.
    static func connect(host: String, port: Int, timeoutMS: Int32) throws -> SSHLink {
        var hints = addrinfo(
            ai_flags: AI_NUMERICSERV,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil)
        var infos: UnsafeMutablePointer<addrinfo>?
        let portString = String(port)
        let rc = getaddrinfo(host, portString, &hints, &infos)
        guard rc == 0, let first = infos else {
            throw SSHLinkError(message: "cannot resolve \(host): gai error \(rc)")
        }
        defer { freeaddrinfo(infos) }

        var lastError = "connection refused"
        for info in sequence(first: first, next: { $0.pointee.ai_next }) {
            let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            guard fd >= 0 else {
                lastError = "socket failed: \(String(cString: strerror(errno)))"
                continue
            }
            // Non-blocking connect + poll(POLLOUT) so the timeout is ours.
            let flags = fcntl(fd, F_GETFL, 0)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            let connectResult = info.pointee.ai_addr!.withMemoryRebound(to: sockaddr.self, capacity: 1) { addr in
                Darwin.connect(fd, addr, info.pointee.ai_addrlen)
            }
            if connectResult == 0 {
                _ = fcntl(fd, F_SETFL, flags)
                return SSHLink(fd: fd)
            }
            guard errno == EINPROGRESS else {
                lastError = "connection refused"
                Darwin.close(fd)
                continue
            }
            var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&p, 1, timeoutMS)
            if ready == 0 {
                lastError = "connect to \(host):\(port) timed out"
                Darwin.close(fd)
                continue
            }
            if ready < 0 {
                lastError = "connect poll failed: \(String(cString: strerror(errno)))"
                Darwin.close(fd)
                continue
            }
            var soError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &length)
            guard soError == 0 else {
                lastError = "connect to \(host):\(port) failed: \(String(cString: strerror(soError)))"
                Darwin.close(fd)
                continue
            }
            _ = fcntl(fd, F_SETFL, flags)
            return SSHLink(fd: fd)
        }
        throw SSHLinkError(message: lastError)
    }

    init(fd: Int32) {
        self.fd = fd
    }

    /// Waits for readability. True = read is possible; false = timed out.
    func waitReadable(timeoutMS: Int32) throws -> Bool {
        guard fd >= 0 else { throw SSHLinkError(message: "not connected") }
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&p, 1, timeoutMS)
        if ready < 0 {
            if errno == EINTR { return false }
            throw SSHLinkError(message: "socket error: poll failed: \(String(cString: strerror(errno)))")
        }
        if p.revents & Int16(POLLNVAL) != 0 || p.revents & Int16(POLLERR) != 0 {
            throw SSHLinkError(message: "socket error: connection closed")
        }
        return ready > 0
    }

    /// One read. Empty array = orderly EOF from the server.
    func readChunk() throws -> [UInt8] {
        guard fd >= 0 else { throw SSHLinkError(message: "not connected") }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let n = buffer.withUnsafeMutableBytes { raw in
            Darwin.read(fd, raw.baseAddress, raw.count)
        }
        if n > 0 { return Array(buffer[0..<n]) }
        if n == 0 { return [] }
        if errno == EINTR || errno == EAGAIN {
            return []                                    // retry later
        }
        throw SSHLinkError(message: "socket error: read failed: \(String(cString: strerror(errno)))")
    }

    /// Writes everything, polling for writability when the buffer is full.
    func writeAll(_ bytes: [UInt8]) throws {
        guard fd >= 0, !bytes.isEmpty else { return }
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBytes { raw in
                Darwin.write(fd, raw.baseAddress, raw.count)
            }
            if n > 0 {
                offset += n
                continue
            }
            if n < 0, errno == EINTR || errno == EAGAIN {
                var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let ready = poll(&p, 1, 5_000)
                if ready == 0 {
                    throw SSHLinkError(message: "socket error: write timed out")
                }
                if ready < 0, errno != EINTR {
                    throw SSHLinkError(message: "socket error: write poll failed: \(String(cString: strerror(errno)))")
                }
                continue
            }
            throw SSHLinkError(message: errno == EPIPE
                ? "broken pipe: the server closed the connection"
                : "socket error: write failed: \(String(cString: strerror(errno)))")
        }
    }

    func close() {
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
    }
}
