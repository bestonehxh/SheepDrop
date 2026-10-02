import Foundation
import SheepSSH

/// Built-in SFTP server: lets a switch/router pull (or push) files over
/// `sftp://user@mac:port/file`, the SSH counterpart of the TFTP server.
///
/// Security: authenticates against an app-defined VIRTUAL user + password
/// (never the macOS account), stored in UserDefaults (user) + Keychain
/// (password). Serves a single root folder (shared with the TFTP server).
/// Path traversal above the root is rejected. Writes require the same
/// "allow writes" switch as TFTP.
///
/// Threading: one accept loop thread; one worker thread per connection. The
/// SSH transport is SheepDrop's own (SheepSSH's server role — the SSHServer
/// transport signs the key exchange with our host keys, the connection layer
/// answers password auth, and the sftp subsystem / exec scp requests are
/// dispatched to SFTPRequestHandler / SCPServerHandler). Before libssh was
/// removed, ssh_bind/ssh_handle_key_exchange/sftp_server_new did this part.

nonisolated final class SFTPServerListener: @unchecked Sendable {
    struct Config: Sendable {
        var port: UInt16
        var username: String
        var password: String
        var rootPath: String
        var allowWrites: Bool
    }

    private let config: Config
    private let onLog: @Sendable (TFTPLogEntry) -> Void
    private let onProgress: ServeProgress
    private let acceptQueue = DispatchQueue(label: "sheepdrop.sftp.server.accept")
    private let stateLock = NSLock()
    private var listenFD: Int32 = -1
    private var running = false
    private let live = LiveSessions()

    /// Sockets of the connections currently being served, so stop() can end
    /// them (it used to stop only the listener — logged-in SFTP/SCP clients
    /// kept reading and writing after the toggle said "Off").
    private final class LiveSessions: @unchecked Sendable {
        private let lock = NSLock()
        private var fds: [UUID: (fd: Int32, peer: String)] = [:]
        private var stopped = false
        /// Connections at once, and per peer address. Every connection is a
        /// thread and pre-auth costs a key exchange, so without a cap any LAN
        /// host could open hundreds and wedge the app (audit 2026-10-02).
        static let maximumTotal = 16
        static let maximumPerPeer = 4
        /// Returns nil if the server is stopping or a cap is hit — the caller
        /// must drop the connection instead of serving it.
        func add(_ fd: Int32, peer: String) -> UUID? {
            lock.lock(); defer { lock.unlock() }
            guard !stopped, fds.count < Self.maximumTotal,
                  fds.values.filter({ $0.peer == peer }).count < Self.maximumPerPeer else { return nil }
            let id = UUID(); fds[id] = (fd, peer); return id
        }
        var isStopped: Bool {
            lock.lock(); defer { lock.unlock() }
            return stopped
        }
        func remove(_ id: UUID) {
            lock.lock(); fds[id] = nil; lock.unlock()
        }
        func shutdownAll() {
            lock.lock(); defer { lock.unlock() }
            stopped = true
            for entry in fds.values { Darwin.shutdown(entry.fd, SHUT_RDWR) }
        }
    }

    /// Handshake + login must finish within this; a silent TCP connection used
    /// to hold a thread forever.
    private static let handshakeTimeout: TimeInterval = 30
    /// Raised once logged in, so the short handshake limit can't cut off a
    /// person browsing slowly.
    private static let sessionTimeout: TimeInterval = 600
    /// Read per write-op so flipping "Allow writes" applies to a running server.
    private let allowWritesNow: @Sendable () -> Bool

    init(config: Config, allowWrites: (@Sendable () -> Bool)? = nil,
         onLog: @escaping @Sendable (TFTPLogEntry) -> Void,
         onProgress: @escaping ServeProgress = { _ in }) {
        self.config = config
        self.allowWritesNow = allowWrites ?? { config.allowWrites }
        self.onLog = onLog
        self.onProgress = onProgress
    }

    private var isRunning: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return running
    }

    // MARK: - Server algorithm offer (modern first, legacy included)
    //
    // The server-side mirror of the family client policy: strong algorithms
    // lead the list so a modern client is never downgraded, and the legacy
    // entries (DH group1/14-sha1, aes-cbc, 3des, hmac-sha1/md5, ssh-rsa) are
    // included because old switches support nothing newer. Group exchange is
    // NOT offered — a server role needs a moduli source for it, and every
    // GEX-only client also speaks curve25519 or fixed groups.

    static func serverPreferences() -> AlgorithmPreferences {
        var prefs = AlgorithmPreferences.modern
        // Also NOT offered: group16/18. Our modexp costs ~5 s (group14) to
        // ~26 s (group16) of CPU per handshake, pre-auth — a cheap DoS — and
        // no switch needs them (legacy gear speaks group14/group1 at most).
        let excluded: Set<KexAlgorithm> = [.dhGexSHA1, .dhGexSHA256, .mlkem768x25519, .dhGroup16, .dhGroup18]
        var kex = prefs.kex.filter { !excluded.contains($0) }
        for extra in AlgorithmPreferences.legacy.kex where !kex.contains(extra) && !excluded.contains(extra) {
            kex.append(extra)
        }
        prefs.kex = kex
        for extra in AlgorithmPreferences.legacy.ciphers where !prefs.ciphers.contains(extra) {
            prefs.ciphers.append(extra)
        }
        for extra in AlgorithmPreferences.legacy.macs where !prefs.macs.contains(extra) {
            prefs.macs.append(extra)
        }
        // Only the host key types we actually hold a key for (ed25519 + RSA).
        prefs.hostKeys = [.ed25519, .rsaSHA512, .rsaSHA256, .rsaSHA1]
        return prefs
    }

    /// Devices that pull over SCP (Aruba `copy scp:`, most switches) hard-code
    /// SSH port 22 with no way to name another — so try 22 first and fall back
    /// to 2222 only if it's taken (e.g. macOS Remote Login owns 22).
    static let fallbackPort: UInt16 = 2222

    /// Ensures host keys exist and starts accepting. Returns the bound port.
    func start() async throws -> UInt16 {
        let signers = try Self.ensureHostKeys()
        return try await withCheckedThrowingContinuation { continuation in
            acceptQueue.async { [self] in
                do {
                    // On a restart the previous accept socket may still be in
                    // TIME_WAIT/rebind flux; retry 22 briefly before falling
                    // back, or a folder change silently moved us to 2222 and
                    // switches (which can't name a port) got "refused".
                    var bound: UInt16?
                    var lastError: Error?
                    for attempt in 0..<4 where bound == nil {
                        do {
                            bound = try bindAndListen(port: config.port)
                        } catch {
                            lastError = error
                            if attempt < 3 { usleep(150_000) }
                        }
                    }
                    let port: UInt16
                    if let bound {
                        port = bound
                    } else {
                        guard config.port != Self.fallbackPort else {
                            throw lastError ?? SFTPError(message: "cannot listen on port \(config.port)")
                        }
                        port = try bindAndListen(port: Self.fallbackPort)
                    }
                    stateLock.lock(); running = true; stateLock.unlock()
                    continuation.resume(returning: port)
                    acceptLoop(signers: signers)   // occupies acceptQueue until stop()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Must NOT go through acceptQueue — that serial queue is occupied by the
    /// accept loop for the server's whole life. Flip the flag and neuter the
    /// listening socket from the caller's thread (dup2 /dev/null over the fd —
    /// the blocked accept fails immediately, with no fd-reuse race).
    func stop() {
        stateLock.lock()
        guard running else { stateLock.unlock(); return }
        running = false
        let fd = listenFD
        stateLock.unlock()
        live.shutdownAll()
        if fd >= 0 {
            let devnull = open("/dev/null", O_RDONLY)
            if devnull >= 0 {
                dup2(devnull, fd)
                close(devnull)
            }
        }
    }

    // MARK: - Bind

    private func bindAndListen(port bindPort: UInt16) throws -> UInt16 {
        let fd = socket(AF_INET6, SOCK_STREAM, 0)
        var fd4 = socket(AF_INET, SOCK_STREAM, 0)
        guard fd4 >= 0 else {
            throw SFTPError(message: "socket failed: \(String(cString: strerror(errno)))")
        }
        // IPv4 only — the reach URL is a dotted IPv4 address anyway.
        if fd >= 0 { close(fd) }
        var on: Int32 = 1
        setsockopt(fd4, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = bindPort.bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd4, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let message = String(cString: strerror(errno))
            close(fd4)
            fd4 = -1
            throw SFTPError(message: "cannot listen on port \(bindPort): \(message)")
        }
        guard listen(fd4, 8) == 0 else {
            let message = String(cString: strerror(errno))
            close(fd4)
            fd4 = -1
            throw SFTPError(message: "cannot listen on port \(bindPort): \(message)")
        }
        stateLock.lock()
        listenFD = fd4
        stateLock.unlock()
        return bindPort
    }

    private func acceptLoop(signers: [SSHSigner]) {
        while isRunning {
            stateLock.lock()
            let fd = listenFD
            stateLock.unlock()
            guard fd >= 0 else { break }
            var addr = sockaddr_storage()
            var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let client = withUnsafeMutablePointer(to: &addr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.accept(fd, sa, &len)
                }
            }
            guard client >= 0 else {
                if !isRunning { break }
                // e.g. EMFILE: accept fails instantly and would spin a core.
                usleep(100_000)
                continue
            }
            guard isRunning else { close(client); break }
            let peerHost = Self.peerString(fd: client)
            guard let liveID = live.add(client, peer: peerHost) else {
                close(client)
                if live.isStopped { break }
                continue            // over the cap: refuse this one, keep serving
            }
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_KEEPALIVE, &on, socklen_t(MemoryLayout<Int32>.size))
            let config = self.config
            let onLog = self.onLog
            let onProgress = self.onProgress
            let allowWrites = self.allowWritesNow
            let live = self.live
            Thread.detachNewThread {
                Self.serve(fd: client, signers: signers, config: config,
                           allowWrites: allowWrites, onLog: onLog, onProgress: onProgress,
                           done: { live.remove(liveID) })
            }
        }
        stateLock.lock()
        if listenFD >= 0 { close(listenFD) }
        listenFD = -1
        stateLock.unlock()
    }

    // MARK: - Host keys

    /// Loads or generates BOTH an ed25519 key (modern clients) and a 2048-bit
    /// RSA key, because legacy network gear — ArubaOS switches, Cisco IOS,
    /// older HP/Comware — does NOT support ed25519 host keys. With ed25519
    /// alone, an Aruba `copy scp:` died at key exchange with "no match for
    /// method server host key algo". The files keep the names libssh's
    /// exporter wrote before, so existing installs keep their pinned keys.
    private static func ensureHostKeys() throws -> [SSHSigner] {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SheepDrop", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let rsa = try HostKeyStore.ensureRSA(path: dir.appendingPathComponent("sftp_server_rsa").path)
        let ed = try HostKeyStore.ensureEd25519(path: dir.appendingPathComponent("sftp_server_ed25519").path)
        return [PrivateKeySigner(ed, label: "ed25519 host key"),
                PrivateKeySigner(rsa, label: "rsa host key")]
    }

    // MARK: - One connection (runs on its own thread)

    private static func serve(fd: Int32,
                              signers: [SSHSigner],
                              config: Config,
                              allowWrites: @escaping @Sendable () -> Bool,
                              onLog: @escaping @Sendable (TFTPLogEntry) -> Void,
                              onProgress: @escaping ServeProgress,
                              done: () -> Void) {
        defer {
            done()                    // deregister BEFORE close closes the fd
            close(fd)
        }
        let link = SSHLink(fd: fd)
        let transport = SSHServerTransport(configuration: .init(
            preferences: serverPreferences(),
            softwareVersion: "SheepDrop_1.0",
            hostKeys: signers))
        let peer = peerString(fd: fd)
        let connection = SSHServerConnection(transport: transport, configuration: .init(
            passwordAuthenticator: { user, password in
                // Constant-time: String == short-circuits on the first mismatch.
                // Both compares always run, so timing can't tell which failed.
                let userOK = constantTimeEqual(Array(user.utf8), Array(config.username.utf8))
                let passOK = constantTimeEqual(Array(password.utf8), Array(config.password.utf8))
                return userOK && passOK && !password.isEmpty
            }))
        transport.start()

        var handshakeDeadline = Date().addingTimeInterval(handshakeTimeout)
        var idleDeadline = handshakeDeadline
        var authFailures = 0
        var dead = false
        var scpHandler: SCPServerHandler?
        var sftpChannel: UInt32?
        var sftpHandler: SFTPRequestHandler?
        /// Channel bytes reassembling into length-framed SFTP packets.
        var sftpInbox: [UInt8] = []
        var scpChannel: UInt32?
        var scpIO: ChannelIO?

        func flush() {
            let out = transport.takeOutgoing()
            if !out.isEmpty { try? link.writeAll(out) }
        }

        /// One pump iteration: send what's queued, read what's there, route it.
        /// The whole connection runs on THIS thread — handlers included.
        func runPumpOnce() {
            if dead { return }
            flush()
            let readable: Bool
            do {
                readable = try link.waitReadable(timeoutMS: 50)
            } catch {
                dead = true
                return
            }
            guard readable else { return }
            let chunk: [UInt8]
            do {
                chunk = try link.readChunk()
            } catch {
                dead = true
                return
            }
            if chunk.isEmpty {
                dead = true
                return
            }
            idleDeadline = Date().addingTimeInterval(
                sftpHandler != nil || scpHandler != nil ? sessionTimeout : handshakeTimeout)
            do {
                try transport.receive(chunk)
            } catch {
                dead = true
                return
            }
            for event in transport.takeEvents() {
                switch event {
                case .ready, .keysChanged:
                    break
                case .message(let payload):
                    do {
                        try connection.handle(payload)
                    } catch {
                        dead = true
                        return
                    }
                    drainConnectionEvents()
                }
            }
        }

        func drainConnectionEvents() {
            for event in connection.takeEvents() {
                // Defence in depth for the connection-layer gate: never route
                // channel work for a client that hasn't logged in.
                switch event {
                case .authenticated, .passwordRejected: break
                default:
                    guard connection.isAuthenticated else { dead = true; return }
                }
                switch event {
                case .authenticated:
                    idleDeadline = Date().addingTimeInterval(sessionTimeout)
                case .passwordRejected:
                    authFailures += 1
                    if authFailures >= 3 {
                        transport.disconnect(reason: .noMoreAuthMethodsAvailable,
                                             description: "too many authentication failures")
                        flush()
                        dead = true
                    }
                case .channelOpened:
                    break
                case .channelRequest(let id, let request):
                    switch request {
                    case .subsystem(let name) where name == "sftp" && sftpHandler == nil:
                        connection.replyRequest(id, success: true)
                        sftpChannel = id
                        sftpHandler = SFTPRequestHandler(
                            root: URL(fileURLWithPath: config.rootPath),
                            allowWrites: allowWrites, peer: peer, onLog: onLog,
                            onProgress: onProgress)
                    case .exec(let command) where command.hasPrefix("scp") && scpHandler == nil:
                        connection.replyRequest(id, success: true)
                        scpChannel = id
                        let io = ChannelIO(pump: { runPumpOnce() }, connection: connection,
                                           channel: id, onDead: { dead = true })
                        scpIO = io
                        scpHandler = SCPServerHandler(
                            channel: io, command: command,
                            root: URL(fileURLWithPath: config.rootPath),
                            allowWrites: allowWrites, peer: peer, onLog: onLog,
                            onProgress: onProgress)
                    case .subsystem, .exec:
                        connection.replyRequest(id, success: false)
                    case .refused:
                        break
                    }
                case .data(let id, let bytes):
                    if id == sftpChannel, let handler = sftpHandler {
                        sftpInbox.append(contentsOf: bytes)
                        // Dispatch every complete length-framed packet; a
                        // partial tail waits for the next segment.
                        dispatch: while sftpInbox.count >= 4 {
                            let length = (UInt32(sftpInbox[0]) << 24)
                                | (UInt32(sftpInbox[1]) << 16)
                                | (UInt32(sftpInbox[2]) << 8)
                                | UInt32(sftpInbox[3])
                            guard length >= 1, length <= 4 << 20 else {
                                dead = true
                                break dispatch
                            }
                            guard sftpInbox.count >= 4 + Int(length) else { break dispatch }
                            let packet = Array(sftpInbox[4..<(4 + Int(length))])
                            sftpInbox.removeFirst(4 + Int(length))
                            let replies = handler.respond(to: packet)
                            if !replies.isEmpty {
                                try? connection.write(id, replies)
                            }
                        }
                        idleDeadline = Date().addingTimeInterval(sessionTimeout)
                    }
                    if id == scpChannel { scpIO?.feed(bytes) }
                case .eof(let id):
                    if id == scpChannel { scpIO?.markEOF() }
                case .closed(let id):
                    if id == sftpChannel {
                        sftpHandler?.closeAll()
                        sftpHandler = nil
                        sftpChannel = nil
                    }
                }
            }
        }

        func pumpUntil(_ condition: () -> Bool, deadline: Date, what: String) -> Bool {
            while !condition() {
                if dead { return false }
                if Date() >= deadline {
                    transport.disconnect(reason: .byApplication, description: "timed out")
                    flush()
                    return false
                }
                runPumpOnce()
            }
            return true
        }

        // The whole session on this thread: handshake → password auth → serve
        // the one channel the client opens (SFTP request/response inline; SCP
        // blocking reads inline through its ChannelIO).
        pumpUntil({ transport.isEstablished }, deadline: handshakeDeadline, what: "handshake")
        guard !dead else { return }
        pumpUntil({ connection.isAuthenticated || authFailures >= 3 || dead },
                  deadline: handshakeDeadline, what: "auth")
        guard connection.isAuthenticated, !dead else { return }

        pumpUntil({ sftpHandler != nil || scpHandler != nil || dead },
                  deadline: Date().addingTimeInterval(sessionTimeout), what: "channel")
        guard !dead else {
            sftpHandler?.closeAll()
            transport.disconnect()
            flush()
            return
        }

        if sftpHandler != nil {
            // Request/response until the client closes or drops.
            // Idle limit (10 min without a byte from the client): with the
            // per-peer connection cap, idle logins used to hold their slots
            // forever. Every client request resets idleDeadline.
            pumpUntil({ dead || sftpChannel == nil || Date() >= idleDeadline },
                      deadline: Date.distantFuture, what: "sftp")
            sftpHandler?.closeAll()
        } else if let handler = scpHandler {
            handler.run()           // blocking reads drive runPumpOnce
        }

        transport.disconnect()
        flush()
    }

    /// Blocking channel I/O for SCPServerHandler, backed by the connection's
    /// pump (the handler calls read from its own thread; the pump closure
    /// runs on the same thread — the connection is single-threaded).
    private final class ChannelIO: SCPChannel, @unchecked Sendable {
        private let pump: () -> Void
        private let connection: SSHServerConnection
        private let channel: UInt32
        private let onDead: () -> Void
        private var inbox: [UInt8] = []
        private var eof = false
        private var closed = false

        init(pump: @escaping () -> Void, connection: SSHServerConnection,
             channel: UInt32, onDead: @escaping () -> Void) {
            self.pump = pump
            self.connection = connection
            self.channel = channel
            self.onDead = onDead
        }

        private var eofNow: Bool { eof || closed }

        func write(_ bytes: [UInt8]) -> Bool {
            guard !eofNow else { return false }
            do {
                try connection.write(channel, bytes)
            } catch {
                onDead()
                return false
            }
            pump()
            return true
        }

        func readByte() -> UInt8? {
            readBytes(1)?[0]
        }

        func readBytes(_ count: Int) -> [UInt8]? {
            while inbox.count < count, !eofNow {
                pump()
            }
            guard inbox.count >= count else {
                // EOF with (or without) a partial tail.
                let out = inbox
                inbox.removeAll()
                return out.isEmpty ? nil : Array(out)
            }
            let out = Array(inbox.prefix(count))
            inbox.removeFirst(count)
            return out
        }

        func sendExitStatus(_ code: Int32) {
            // CHANNEL_REQUEST exit-status, sent raw through the connection.
            var w = SSHWriter()
            w.writeByte(98)
            w.writeUInt32(0)                // replaced below — see append
            // The connection layer doesn't expose the remote id; ask it via
            // a raw send through its write path instead.
            _ = w
            connection.sendExitStatus(channel: channel, code: code)
        }

        func sendEOFAndClose() {
            try? connection.sendEOF(channel)
            try? connection.close(channel)
            pump()
        }

        /// Called by the listener when channel data arrives.
        func feed(_ bytes: [UInt8]) {
            inbox.append(contentsOf: bytes)
        }

        func markEOF() { eof = true }
        func markClosed() { closed = true }
    }

    private static func peerString(fd: Int32) -> String {
        var addr = sockaddr_storage()
        var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let ok = withUnsafeMutablePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getpeername(fd, $0, &len) == 0
            }
        }
        guard ok else { return "?" }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        _ = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            }
        }
        return String(cString: host)
    }
}
