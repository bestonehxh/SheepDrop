import Foundation
import SheepSSH

struct SFTPConfig: Sendable {
    var host: String
    var port: Int
    var username: String
    var password: String?
    /// Overrides ~/.ssh/known_hosts — used by the test harness so throwaway
    /// server keys never land in the user's real file. nil = system default.
    var knownHostsPath: String?
}

struct SFTPError: Error, Sendable {
    var message: String
    /// True when the failure was an authentication rejection — the UI
    /// re-prompts for the password instead of showing a dead error.
    var isAuthFailure = false
}

/// One SSH session + SFTP subsystem channel on its own serial queue, built
/// entirely on SheepSSH (SheepTerm's in-house SSH stack — the app bundles no
/// libssh/OpenSSL dylibs any more). Modeled on SheepTerm's SSHWorker: modern
/// algorithms first with a legacy-set retry for old Cisco/Aruba gear, and the
/// same fail-closed known_hosts policy.
///
/// SheepSSH is sans-I/O, so this class is also the socket owner: one POSIX
/// link, a poll-driven pump on `queue` that feeds the transport and routes
/// its events to the auth layer, the connection layer, and the SFTP/SCP
/// state machines. Every public op marshals onto `queue`; all state below is
/// queue-confined (the @unchecked Sendable contract).
nonisolated final class SFTPWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "sheepdrop.sftp.engine")

    // Queue-confined — see class comment.
    private var link: SSHLink?
    private var transport: SSHTransport?
    private var auth: SSHUserAuth?
    private var connection: SSHConnection?
    private var sftpClient: SFTPProtocolClient?
    private var sftpChannel: UInt32?
    private var sftpReady = false
    private var scp: SCPTransfer?
    private var scpChannel: UInt32?
    /// Set by event handling when a pump must fail (host key refused, channel
    /// open failed, …); the next pump iteration throws it.
    private var pumpError: SFTPError?
    /// First-connection host-key notice, for the connect() return value.
    private var hostKeyNotice: String?
    private var channelOpened = false
    private var channelReply: (request: String, success: Bool)?
    private var channelClosed = false

    deinit {
        // The owner is expected to call disconnect(); this is the backstop.
        let link = self.link
        if link != nil {
            queue.async { link?.close() }
        }
    }

    // MARK: - Async surface (call from anywhere)

    /// Connects and opens the SFTP channel. Returns a human-readable notice
    /// (first-connection host-key message) or nil.
    func connect(_ config: SFTPConfig) async throws -> String? {
        try await onQueue { try $0.doConnect(config, openSFTP: true) }
    }

    /// Connect + authenticate only.
    func connectSSHOnly(_ config: SFTPConfig) async throws -> String? {
        try await onQueue { try $0.doConnect(config, openSFTP: false) }
    }

    /// SCP connect, WinSCP-style: authenticate, then *try* to open the SFTP
    /// subsystem for browsing. If the device serves it, the session becomes
    /// fully browsable (list/enter/download/upload all run over SFTP, same as an
    /// SFTP host); if the device refuses it (e.g. some Aruba CX builds), we stay
    /// connected and fall back to blind SCP put/get. `browsable` says which.
    func connectSCP(_ config: SFTPConfig) async throws -> (notice: String?, browsable: Bool) {
        try await onQueue {
            let notice = try $0.doConnect(config, openSFTP: true, sftpOptional: true)
            return (notice, $0.sftpReady)
        }
    }

    func scpUpload(localURL: URL, to remotePath: String,
                   progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        try await onQueue { $0.cancel.reset(); return try $0.doSCP(localURL: localURL, remotePath: remotePath, isPush: true, progress: progress) }
    }

    func scpDownload(remotePath: String, to localURL: URL,
                     progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        try await onQueue { $0.cancel.reset(); return try $0.doSCP(localURL: localURL, remotePath: remotePath, isPush: false, progress: progress) }
    }

    /// Stops the transfer in flight at its next chunk (any thread).
    let cancel = TransferCancel()
    func cancelTransfer() { cancel.request() }

    func disconnect() {
        queue.async { [self] in
            teardown()
        }
    }

    /// Server-side canonical path of the login directory.
    func homeDirectory() async throws -> String {
        try await onQueue { try $0.doHomeDirectory() }
    }

    func listDirectory(_ path: String) async throws -> [FileEntry] {
        try await onQueue { try $0.doList(path) }
    }

    func download(remotePath: String, to localURL: URL,
                  progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        try await onQueue { $0.cancel.reset(); return try $0.doDownload(remotePath, localURL, progress) }
    }

    func upload(localURL: URL, to remotePath: String,
                progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        try await onQueue { $0.cancel.reset(); return try $0.doUpload(localURL, remotePath, progress) }
    }

    private func onQueue<T: Sendable>(_ body: @escaping @Sendable (SFTPWorker) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try body(self) })
            }
        }
    }

    // MARK: - Queue-side plumbing

    private func teardown() {
        if let id = sftpChannel { try? connection?.close(id) }
        if let id = scpChannel { try? connection?.close(id) }
        sftpChannel = nil
        scpChannel = nil
        sftpClient = nil
        scp = nil
        connection = nil
        auth = nil
        // Politely tell the server we are leaving, then drop the socket.
        transport?.disconnect()
        flushTransportOutgoing()
        link?.close()
        link = nil
        transport = nil
        sftpReady = false
    }

    private func flushTransportOutgoing() {
        guard let transport, let link else { return }
        let out = transport.takeOutgoing()
        if !out.isEmpty {
            try? link.writeAll(out)
        }
    }

    private func dead(_ message: String) -> SFTPError {
        SFTPError(message: message)
    }

    /// The pump: services the socket, feeding the transport and routing its
    /// events, until `done` is true. The idle deadline resets on every byte
    /// from the server, so a big transfer that moves never times out — only a
    /// truly silent peer does.
    private var idleDeadline = Date()
    private var stderrText = ""

    private func pump(idleSeconds: TimeInterval, until done: () throws -> Bool) throws {
        idleDeadline = Date().addingTimeInterval(idleSeconds)
        while true {
            if try done() { return }
            if let error = pumpError { throw error }
            guard let link, let transport else { throw dead("not connected") }

            // Anything the connection layer queued for the channel goes out
            // before we wait (scp chunks, window-driven writes).
            if let scp, let id = scpChannel, !scp.isFinished {
                var chunk = scp.outgoing
                // Backpressure: only read more of the file while the channel
                // has < 256 KB queued. Without it a push read the whole file
                // into memory as fast as the disk allowed (and the bar hit
                // 100% long before the bytes left) on any slow link.
                if chunk.isEmpty, (connection?.pendingOutput(id) ?? 0) < 256 * 1024 {
                    // Output-producing steps (sendingData) run without input.
                    do { try scp.feed([]) } catch { pumpError = error }
                    chunk = scp.outgoing
                }
                if !chunk.isEmpty {
                    try? connection?.write(id, chunk)
                }
            }
            flushTransportOutgoing()

            let readable = try link.waitReadable(timeoutMS: 50)
            if readable {
                let chunk = try link.readChunk()
                if chunk.isEmpty {
                    throw dead("connection closed by server")
                }
                idleDeadline = Date().addingTimeInterval(idleSeconds)
                do {
                    try transport.receive(chunk)
                } catch let error as SSHTransportError {
                    throw dead(describe(error))
                }
                try drainTransportEvents()
            }
            if Date() >= idleDeadline {
                throw dead("timed out waiting for the server")
            }
        }
    }

    private func drainTransportEvents() throws {
        guard let transport else { return }
        for event in transport.takeEvents() {
            switch event {
            case .ready, .keysChanged:
                break
            case .message(let payload):
                if let auth, !auth.isAuthenticated {
                    do {
                        for authEvent in try auth.handle(payload) {
                            try handleAuthEvent(authEvent)
                        }
                    } catch let error as UserAuthError {
                        throw dead(describe(error))
                    }
                } else if let connection {
                    do {
                        try connection.handle(payload)
                    } catch {
                        throw dead("connection closed: \(error)")
                    }
                    try drainConnectionEvents()
                }
            }
        }
    }

    private func drainConnectionEvents() throws {
        guard let connection else { return }
        for event in connection.takeEvents() {
            switch event {
            case .channelOpened(let id):
                if id == sftpChannel { channelOpened = true }
                if id == scpChannel { channelOpened = true }
            case .channelOpenFailed(_, _, let description):
                pumpError = dead("the device refused the channel: \(description)")
            case .channelRequestReply(let id, let request, let success):
                if id == sftpChannel || id == scpChannel {
                    channelReply = (request, success)
                }
            case .data(let id, let bytes):
                idleDeadline = Date().addingTimeInterval(20)
                if id == sftpChannel, let client = sftpClient {
                    do {
                        _ = try client.consume(bytes)
                    } catch let error as SFTPProtocolError {
                        // A desynced SFTP stream can't be trusted again: report
                        // it as a dropped connection so the session reconnects.
                        pumpError = dead("connection closed (\(error.message))")
                    }
                }
                if id == scpChannel, let scp {
                    do {
                        try scp.feed(bytes)
                    } catch let error as SFTPError {
                        pumpError = error
                    }
                }
            case .extendedData(let id, let bytes):
                // stderr: some devices explain scp failures there.
                if id == scpChannel, !bytes.isEmpty {
                    stderrText += String(decoding: bytes, as: UTF8.self)
                    idleDeadline = Date().addingTimeInterval(20)
                }
            case .eof, .exitStatus, .exitSignal, .globalReply, .agentChannelOpened:
                break
            case .closed(let id):
                if id == scpChannel, let scp, !scp.isFinished {
                    pumpError = dead("channel is closed")
                }
                if id == sftpChannel, sftpReady {
                    pumpError = dead("channel is closed")
                }
                channelClosed = true
            }
        }
    }

    // MARK: - Connect

    private func doConnect(_ config: SFTPConfig, openSFTP: Bool,
                           sftpOptional: Bool = false) throws -> String? {
        guard link == nil else { return nil }
        var notice: String?

        // Modern algorithms first; retry with the legacy set for old gear.
        var candidate = try makeConnectedSession(config, legacy: false)
        if candidate == nil {
            candidate = try makeConnectedSession(config, legacy: true)
        }
        guard let connected = candidate else {
            throw pumpError ?? dead("connection failed")
        }
        link = connected.link
        transport = connected.transport

        do {
            try runAuth(config)
            // Connection-layer messages only exist after authentication —
            // anything earlier belongs to the auth layer.
            connection = SSHConnection(transport: connected.transport)
            if openSFTP {
                try openSFTPSubsystem(optional: sftpOptional)
            }
            notice = hostKeyNotice
            return notice
        } catch {
            teardown()
            throw error
        }
    }

    /// Socket + transport handshake. Returns nil (with `pumpError` set) when
    /// the TCP/SSH handshake fails so the caller can retry with the legacy
    /// algorithm set.
    private func makeConnectedSession(_ config: SFTPConfig,
                                      legacy: Bool) throws -> (link: SSHLink, transport: SSHTransport)? {
        pumpError = nil
        hostKeyNotice = nil
        let link: SSHLink
        do {
            link = try SSHLink.connect(host: config.host, port: config.port, timeoutMS: 15_000)
        } catch let error as SSHLinkError {
            pumpError = dead(error.message)
            return nil
        }
        let noticeBox = NoticeBox()
        let configuration = SSHTransport.Configuration(
            preferences: legacy ? .legacy : .modern,
            hostKeyValidator: makeValidator(config, box: noticeBox))
        let transport = SSHTransport(configuration: configuration)
        transport.start()
        self.link = link
        self.transport = transport
        defer {
            self.link = nil
            self.transport = nil
        }
        do {
            try pump(idleSeconds: 15) { transport.isEstablished }
        } catch {
            link.close()
            // A refused host key is final — never retry with legacy sets.
            if let refused = noticeBox.error {
                pumpError = dead(refused)
                throw pumpError!
            }
            if let pumpError { throw pumpError }
            // Negotiation / handshake failure: the caller retries legacy.
            pumpError = (error as? SFTPError) ?? dead("connection failed")
            return nil
        }
        hostKeyNotice = noticeBox.notice
        if let refused = noticeBox.error {
            pumpError = dead(refused)
            link.close()
            throw pumpError!
        }
        return (link, transport)
    }

    /// Fail closed, exactly like SheepTerm: an unreadable known_hosts or a
    /// changed key refuses the connection; unknown keys are pinned.
    private func makeValidator(_ config: SFTPConfig, box: NoticeBox)
        -> @Sendable (SSHPublicKey) -> Bool {
        return { key in
            let path = config.knownHostsPath ?? NSHomeDirectory() + "/.ssh/known_hosts"
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
                guard FileManager.default.fileExists(atPath: path) else {
                    // No known_hosts yet: this IS the first connection.
                    return Self.pin(key, host: config.host, port: config.port, path: path, box: box)
                }
                box.error = "cannot read \(path) — refusing to trust any host key. Fix or remove the file, then reconnect."
                return false
            }
            let hosts = KnownHosts(text: text)
            switch hosts.lookup(host: config.host, port: config.port, key: key) {
            case .ok:
                return true
            case .changed:
                box.error = "HOST KEY CHANGED — possible man-in-the-middle. If the device was reinstalled, remove its entry from \(path) and reconnect."
                return false
            case .otherType:
                box.error = "HOST KEY TYPE CHANGED — the server offered a different key type than the one pinned in \(path) (possible man-in-the-middle). If the device was reconfigured, remove its entry and reconnect."
                return false
            case .revoked:
                box.error = "the server's host key is marked @revoked in \(path)."
                return false
            case .notFound:
                return Self.pin(key, host: config.host, port: config.port, path: path, box: box)
            }
        }
    }

    /// Appends one known_hosts entry in place. The file is shared with
    /// OpenSSH and SheepTerm, so: O_APPEND under flock (two tabs pinning at
    /// once used to lose one pin to a read-modify-write race; rewriting the
    /// file also replaced a symlinked known_hosts with a copy), a newline
    /// first when the file doesn't end in one (else the entry was glued onto
    /// the last line, corrupting BOTH keys — an existing pin vanished and a
    /// different key was later accepted as "first connection"), and exactly
    /// one newline after.
    static func appendKnownHost(_ entry: String, to path: String) -> Bool {
        var line = entry.hasSuffix("\n") ? entry : entry + "\n"
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { return false }
        defer { flock(fd, LOCK_UN) }
        var st = stat()
        if fstat(fd, &st) == 0, st.st_size > 0 {
            let reader = open(path, O_RDONLY)
            if reader >= 0 {
                var last: UInt8 = 0
                if pread(reader, &last, 1, off_t(st.st_size - 1)) == 1, last != 0x0A {
                    line = "\n" + line
                }
                close(reader)
            }
        }
        let bytes = Array(line.utf8)
        let written = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
        return written == bytes.count
    }

    private static func pin(_ key: SSHPublicKey, host: String, port: Int, path: String, box: NoticeBox) -> Bool {
        let saved = appendKnownHost(KnownHosts.line(host: host, port: port, key: key), to: path)
        if saved {
            box.notice = "first connection — host key saved to known_hosts"
        } else {
            box.notice = "host key could NOT be saved to known_hosts"
        }
        // A pinned-but-unsaved key still trusts this one connection, like
        // libssh did — the user is warned by the notice.
        return true
    }

    // MARK: - Authentication

    private func runAuth(_ config: SFTPConfig) throws {
        guard let transport else { throw dead("not connected") }
        let username = config.username.isEmpty ? NSUserName() : config.username
        let auth = SSHUserAuth(transport: transport, username: username)
        self.auth = auth
        lastFailureMethods = []
        do {
            try auth.requestService()
        } catch {
            throw dead("authentication could not start: \(error)")
        }
        try pump(idleSeconds: 15) { auth.serviceAccepted }

        // none → password → keyboard-interactive → default keys. Password
        // methods FIRST: offering agent keys before them burns a network
        // device's MaxAuthTries — an Aruba CX would then reject the correct
        // password because the attempt budget was spent on keys the switch
        // never wanted.
        do {
            try auth.tryNone()
        } catch {
            throw dead("authentication could not start: \(error)")
        }
        try pump(idleSeconds: 15) { authAttemptSettled }
        if auth.isAuthenticated { return }

        var methods = lastFailureMethods
        if methods.isEmpty {
            methods = ["password", "keyboard-interactive", "publickey"]
        }
        var failures: [String] = []

        if let password = config.password, !password.isEmpty {
            if methods.contains("password") {
                try attempt { try auth.tryPassword(password) }
                try pump(idleSeconds: 15) { authAttemptSettled }
                if auth.isAuthenticated { return }
                failures.append("password rejected")
            }
            if methods.contains("keyboard-interactive") {
                try attempt { try auth.startKeyboardInteractive() }
                try pumpKeyboardInteractive(auth, password: password, username: username)
                if auth.isAuthenticated { return }
                failures.append("keyboard-interactive rejected")
            }
        }
        if methods.contains("publickey") {
            if try tryDefaultKeys(auth) { return }
        }

        guard let password = config.password, !password.isEmpty else {
            throw SFTPError(message: "password required", isAuthFailure: true)
        }
        var offered: [String] = []
        if methods.contains("password") { offered.append("password") }
        if methods.contains("keyboard-interactive") { offered.append("keyboard-interactive") }
        if methods.contains("publickey") { offered.append("publickey") }
        let detail = failures.isEmpty ? "" : " (\(failures.joined(separator: "; ")))"
        throw SFTPError(
            message: "authentication failed for \(username)@\(config.host) — server accepts: \(offered.joined(separator: ", "))\(detail)",
            isAuthFailure: true)
    }

    private var lastFailureMethods: [String] = []
    private var pendingInfoRequest: SSHUserAuth.InfoRequest?
    /// The server accepted the probed public key (USERAUTH_PK_OK): sign next.
    private var pkAccepted = false
    /// The server answered the attempt in flight with a failure of any shape.
    /// Keyed off the method list before, so a FAILURE naming no methods or a
    /// password-change demand waited out the 15 s timeout and then showed a
    /// "timed out" that wasn't an auth failure (no re-prompt).
    private var attemptRefused = false

    /// True once the auth attempt in flight answered (success or failure).
    private var authAttemptSettled: Bool {
        guard let auth else { return false }
        return auth.isAuthenticated || attemptRefused || pkAccepted
    }

    private func handleAuthEvent(_ event: SSHUserAuth.Event) throws {
        switch event {
        case .success, .serviceAccepted, .banner:
            break
        case .passwordChangeRequested:
            attemptRefused = true       // we can't change it here: a refusal
        case .publicKeyAcceptable:
            pkAccepted = true
        case .failure(_, let methods, _):
            lastFailureMethods = methods
            attemptRefused = true
        case .infoRequest(let info):
            pendingInfoRequest = info
        }
    }

    private func attempt(_ body: () throws -> Void) throws {
        lastFailureMethods = []
        attemptRefused = false
        pendingInfoRequest = nil
        pkAccepted = false
        do {
            try body()
        } catch {
            throw dead("authentication could not start: \(error)")
        }
    }

    /// AOS-CX and TACACS setups often accept ONLY keyboard-interactive.
    /// Non-echo prompts get the password; echo prompts asking for a
    /// user/login name get the username.
    private func pumpKeyboardInteractive(_ auth: SSHUserAuth, password: String, username: String) throws {
        while !authAttemptSettled || pendingInfoRequest != nil {
            if let info = pendingInfoRequest {
                pendingInfoRequest = nil
                var answers: [String] = []
                for prompt in info.prompts {
                    let text = prompt.text.lowercased()
                    if !prompt.echo {
                        answers.append(password)
                    } else if text.contains("user") || text.contains("login") || text.contains("name") {
                        answers.append(username)
                    } else {
                        throw dead("keyboard-interactive asked “\(prompt.text)” — no way to answer it yet")
                    }
                }
                do {
                    try auth.respond(answers)
                } catch {
                    throw dead("keyboard-interactive answer error: \(error)")
                }
            }
            try pump(idleSeconds: 15) { authAttemptSettled || pendingInfoRequest != nil }
        }
    }

    /// Offers ~/.ssh's default keys (like the old publickey_auto): probe each
    /// one, sign the ones the server would accept. True when one authenticated.
    private func tryDefaultKeys(_ auth: SSHUserAuth) throws -> Bool {
        let entries = DefaultIdentities.load(directory: NSHomeDirectory() + "/.ssh")
        for entry in entries {
            guard case .ready(let signer) = entry else { continue }
            let algorithm = publicKeyAlgorithm(for: signer.publicKey,
                                               accepted: AlgorithmPreferences.modern.hostKeys,
                                               serverSignatureAlgorithms: transport?.serverSignatureAlgorithms)
                ?? signer.publicKey.keyType
            lastFailureMethods = []
            pkAccepted = false
            do {
                try auth.queryPublicKey(signer.publicKey, algorithm: algorithm)
            } catch {
                continue
            }
            try pump(idleSeconds: 15) { authAttemptSettled }
            if auth.isAuthenticated { return true }
            guard pkAccepted else { continue }
            lastFailureMethods = []
            pkAccepted = false
            do {
                try auth.tryPublicKey(signer, algorithm: algorithm)
            } catch {
                continue
            }
            try pump(idleSeconds: 15) { authAttemptSettled }
            if auth.isAuthenticated { return true }
        }
        return false
    }

    // MARK: - SFTP subsystem

    private func openSFTPSubsystem(optional: Bool) throws {
        guard let connection else { throw dead("not connected") }
        let client = SFTPProtocolClient()
        let refusal = "the device refused the SFTP subsystem — many network devices (e.g. this CX build) only serve SCP. Add this host again with protocol SCP."

        let id: UInt32
        do {
            id = try connection.openSession()
        } catch {
            throw dead("cannot open a channel: \(error)")
        }
        sftpChannel = id
        sftpClient = client
        channelOpened = false
        channelReply = nil
        try pump(idleSeconds: 15) { channelOpened || pumpError != nil }
        do {
            try connection.requestSubsystem(id, "sftp")
        } catch {
            throw dead("cannot start SFTP: \(error)")
        }
        try pump(idleSeconds: 15) { channelReply != nil || pumpError != nil }
        if channelReply?.success != true {
            sftpClient = nil
            sftpChannel = nil
            if optional { return }
            throw dead("\(refusal)")
        }
        try connection.write(id, client.versionPacket())
        try pump(idleSeconds: 15) { client.serverVersion != 0 || pumpError != nil }
        guard client.serverVersion >= 3 else {
            sftpClient = nil
            sftpChannel = nil
            if optional { return }
            throw dead("the device speaks SFTP version \(client.serverVersion), not v3")
        }
        // The VERSION reply is drained above; nothing of it belongs to the
        // request pipeline the ops use.
        client.drainPending()
        sftpReady = true
    }

    /// One SFTP request/response round trip.
    private func sftpRoundTrip(_ packet: [UInt8], idleSeconds: TimeInterval = 30) throws
        -> SFTPProtocolClient.Reply {
        let requestID = try sftpSend(packet)
        guard let client = sftpClient else { throw dead("not connected") }
        var reply: SFTPProtocolClient.Reply?
        do {
            try pump(idleSeconds: idleSeconds) {
                reply = client.takeReply(for: requestID)
                return reply != nil
            }
        } catch {
            client.forget(requestID)         // its late reply must not match a later call
            throw error
        }
        guard let reply else { throw dead("timed out waiting for the server") }
        return reply
    }

    /// Sends a request built by `sftpClient` without waiting; returns its id.
    private func sftpSend(_ packet: [UInt8]) throws -> UInt32 {
        guard let connection, let client = sftpClient, let id = sftpChannel, sftpReady else {
            throw dead("not connected")
        }
        do {
            try connection.write(id, packet)
        } catch {
            throw dead("connection closed: \(error)")
        }
        return client.latestRequestID
    }

    /// Waits for the first reply to any request in flight (pipelined I/O).
    private func sftpAwaitAny(idleSeconds: TimeInterval = 30) throws -> (id: UInt32, reply: SFTPProtocolClient.Reply) {
        guard let client = sftpClient else { throw dead("not connected") }
        var got: (id: UInt32, reply: SFTPProtocolClient.Reply)?
        try pump(idleSeconds: idleSeconds) {
            got = client.takeAnyReply()
            return got != nil
        }
        guard let got else { throw dead("timed out waiting for the server") }
        return got
    }

    private func requireHandle(_ reply: SFTPProtocolClient.Reply, what: String) throws -> [UInt8] {
        switch reply {
        case .handle(let handle):
            return handle
        case .status(_, let message):
            throw dead("\(what): \(message.isEmpty ? "refused" : message)")
        default:
            throw dead("\(what): unexpected reply")
        }
    }

    // MARK: - SFTP operations

    private func doHomeDirectory() throws -> String {
        pumpError = nil
        let reply = try sftpRoundTrip(sftpClient!.realpathPacket("."))
        switch reply {
        case .names(let names):
            guard let first = names.first else { throw dead("the device returned no home path") }
            return first.name
        case .status(_, let message):
            throw dead("canonicalize failed: \(message.isEmpty ? "refused" : message)")
        default:
            throw dead("canonicalize failed")
        }
    }

    private func doList(_ path: String) throws -> [FileEntry] {
        pumpError = nil
        guard let client = sftpClient else { throw dead("not connected") }
        let open = try sftpRoundTrip(client.openDirPacket(path))
        let handle = try requireHandle(open, what: "cannot open \(path)")

        var entries: [FileEntry] = []
        reading: while true {
            let reply = try sftpRoundTrip(client.readDirPacket(handle))
            switch reply {
            case .names(let names):
                for entry in names {
                    let name = entry.name
                    if name == "." || name == ".." { continue }
                    if name.hasPrefix(".") { continue }
                    // A directory is one the server flags as a dir by TYPE **or** by the
                    // POSIX S_IFDIR bit. Many SFTP servers (network gear especially)
                    // leave `type` as UNKNOWN and only set permissions — relying on
                    // `type` alone made every folder look like a file.
                    let perms = entry.attrs.permissions
                    let isDirectory = entry.attrs.type == 2
                        || (perms != nil && (perms! & UInt32(S_IFMT)) == UInt32(S_IFDIR))
                    entries.append(FileEntry(
                        name: name,
                        isDirectory: isDirectory,
                        size: Int64(bitPattern: entry.attrs.size ?? 0),
                        modified: entry.attrs.mtime.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                        permissions: Self.permissionString(perms ?? 0, isDirectory: isDirectory)
                    ))
                }
            case .status(let code, let message):
                if code == SFTPProtocolClient.Status.eof { break reading }
                throw dead("cannot list \(path): \(message.isEmpty ? "refused" : message)")
            default:
                throw dead("cannot list \(path): unexpected reply")
            }
        }
        // Close the handle; a refused close still leaves the listing valid.
        _ = try? sftpRoundTrip(client.closePacket(handle))
        return entries.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func doDownload(_ remotePath: String, _ localURL: URL,
                            _ progress: @Sendable (Int64, Int64) -> Void) throws {
        pumpError = nil
        guard let client = sftpClient else { throw dead("not connected") }
        var total: Int64 = 0
        if case .attrs(let attrs) = (try? sftpRoundTrip(client.statPacket(remotePath))) {
            total = Int64(bitPattern: attrs.size ?? 0)
        }

        let open = try sftpRoundTrip(client.openReadPacket(remotePath))
        let handle = try requireHandle(open, what: "cannot open \(remotePath)")

        FileManager.default.createFile(atPath: localURL.path, contents: nil)
        guard let out = try? FileHandle(forWritingTo: localURL) else {
            throw dead("cannot write \(localURL.lastPathComponent)")
        }
        defer { try? out.close() }

        // Pipelined like OpenSSH's sftp: 64 READs of 32 KB in flight. One
        // READ per round trip capped a transfer at chunk/RTT (~4–5 MB/s even
        // on loopback); 32 KB is a size every device answers in full.
        // Replies may arrive out of order — each lands at its own offset.
        let chunk = 32 * 1024, window = 64
        var inFlight: [UInt32: (offset: UInt64, length: Int)] = [:]
        defer { for id in inFlight.keys { client.forget(id) } }
        var nextOffset: UInt64 = 0
        var done: Int64 = 0
        var reachedEOF = false

        func issue(_ offset: UInt64, _ length: Int) throws {
            let id = try sftpSend(client.readPacket(handle: handle, offset: offset, length: length))
            inFlight[id] = (offset, length)
        }

        while true {
            while !reachedEOF, inFlight.count < window, total == 0 || nextOffset < UInt64(total) {
                try issue(nextOffset, chunk)
                nextOffset += UInt64(chunk)
            }
            if inFlight.isEmpty { break }
            let (id, reply) = try sftpAwaitAny()
            guard let request = inFlight.removeValue(forKey: id) else { continue }
            switch reply {
            case .data(let bytes):
                if bytes.isEmpty { throw dead("read failed at \(done) bytes") }
                try out.seek(toOffset: request.offset)
                try out.write(contentsOf: Data(bytes))
                done += Int64(bytes.count)
                // A short read (server's own cap) before EOF: ask for the rest.
                if bytes.count < request.length {
                    try issue(request.offset + UInt64(bytes.count), request.length - bytes.count)
                }
                progress(done, total)
                if cancel.isRequested {
                    _ = try? sftpRoundTrip(client.closePacket(handle))
                    throw TransferCancel.error
                }
            case .status(let code, let message):
                // EOF for a request past the end — expected when the size was
                // unknown (0: empty file or a virtual running-config); stop
                // issuing more. Any other status is a real failure.
                guard code == SFTPProtocolClient.Status.eof else {
                    throw dead("read failed at \(done) bytes: \(message)")
                }
                reachedEOF = true
            default:
                throw dead("read failed at \(done) bytes")
            }
        }
        if total > 0, done < total {
            throw SFTPError(message: "\(remotePath) ended early: \(done) of \(total) bytes")
        }
        // Close the handle; a refused close still leaves the file complete.
        _ = try? sftpRoundTrip(client.closePacket(handle))
        if total == 0 {
            progress(done, done)
        }
    }

    private func doUpload(_ localURL: URL, _ remotePath: String,
                          _ progress: @Sendable (Int64, Int64) -> Void) throws {
        pumpError = nil
        guard let client = sftpClient else { throw dead("not connected") }
        guard let input = try? FileHandle(forReadingFrom: localURL) else {
            throw dead("cannot read \(localURL.lastPathComponent)")
        }
        defer { try? input.close() }
        let total = Int64((try? localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)

        let open = try sftpRoundTrip(client.openWritePacket(remotePath, truncate: true))
        let handle = try requireHandle(open, what: "cannot create \(remotePath)")

        // Pipelined: up to 64 WRITEs of 32 KB in flight (32 KB fits every
        // server's max packet). A status that isn't OK fails the upload.
        let chunk = 32 * 1024, window = 64
        var inFlight: [UInt32: Int] = [:]                 // id → bytes
        defer { for id in inFlight.keys { client.forget(id) } }
        var offset: UInt64 = 0
        var done: Int64 = 0
        var readAll = false

        while true {
            while !readAll, inFlight.count < window {
                guard let data = try input.read(upToCount: chunk), !data.isEmpty else {
                    readAll = true
                    break
                }
                let bytes = Array(data)
                let id = try sftpSend(client.writePacket(handle: handle, offset: offset, bytes[...]))
                inFlight[id] = bytes.count
                offset += UInt64(bytes.count)
            }
            if inFlight.isEmpty { break }
            let (id, reply) = try sftpAwaitAny()
            guard let count = inFlight.removeValue(forKey: id) else { continue }
            switch reply {
            case .status(let code, let message):
                guard code == SFTPProtocolClient.Status.ok else {
                    throw dead("write failed at \(done) bytes: \(message.isEmpty ? "refused" : message)")
                }
            default:
                throw dead("write failed at \(done) bytes")
            }
            done += Int64(count)
            progress(done, total)
            if cancel.isRequested {
                _ = try? sftpRoundTrip(client.closePacket(handle))
                throw TransferCancel.error
            }
        }
        // Close the handle; a refused close still leaves the file complete.
        _ = try? sftpRoundTrip(client.closePacket(handle))
    }

    // MARK: - SCP (exec-channel transfers over the authenticated session)

    private func doSCP(localURL: URL, remotePath: String, isPush: Bool,
                       progress: @escaping @Sendable (Int64, Int64) -> Void) throws {
        guard let connection else { throw dead("not connected") }
        pumpError = nil
        stderrText = ""
        let transfer: SCPTransfer
        if isPush {
            // "flash:/img.swi" → location "flash:", name "img.swi"; a path
            // with no slash (CX "primary") is the location and keeps the
            // local file name.
            let (location, name) = Self.splitRemotePath(remotePath, fallbackName: localURL.lastPathComponent)
            transfer = try SCPTransfer(push: location, name: name, localURL: localURL)
        } else {
            transfer = try SCPTransfer(pull: remotePath, localURL: localURL)
        }
        scp = transfer
        defer { scp = nil }

        let channel: UInt32
        do {
            channel = try connection.openSession()
        } catch {
            throw dead("cannot open a channel: \(error)")
        }
        scpChannel = channel
        defer { scpChannel = nil }
        channelOpened = false
        channelReply = nil
        try pump(idleSeconds: 15) { channelOpened || pumpError != nil }
        do {
            try connection.requestExec(channel, command: transfer.command)
        } catch {
            throw dead("scp refused for “\(remotePath)”: \(error)")
        }
        try pump(idleSeconds: 15) { channelReply != nil || pumpError != nil }
        guard channelReply?.success == true else {
            throw dead("scp refused for “\(remotePath)” — the device has no scp")
        }
        try transfer.beginExecApproved()

        var lastReported: Int64 = -1
        try pump(idleSeconds: 20) {
            if transfer.done != lastReported {
                lastReported = transfer.done
                progress(transfer.done, transfer.total)
            }
            return transfer.isFinished || cancel.isRequested
        }
        if cancel.isRequested, !transfer.isFinished {
            _ = try? connection.close(channel)
            throw TransferCancel.error
        }
        if let message = transfer.failureMessage {
            throw dead(message)
        }
        if !stderrText.isEmpty {
            throw dead(stderrText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        progress(transfer.done, transfer.total)
        _ = try? connection.close(channel)
    }

    /// "flash:/img.swi" → ("flash:", "img.swi"); "backups/run.cfg" →
    /// ("backups", "run.cfg"); "primary" (no slash) → ("primary", local name).
    static func splitRemotePath(_ remotePath: String, fallbackName: String) -> (location: String, name: String) {
        guard let slash = remotePath.lastIndex(of: "/") else {
            return (remotePath, fallbackName)
        }
        let name = String(remotePath[remotePath.index(after: slash)...])
        let location = String(remotePath[..<slash])
        return (location.isEmpty ? "/" : location, name.isEmpty ? fallbackName : name)
    }

    /// 0o755 → "drwxr-xr-x", ls style.
    static func permissionString(_ mode: UInt32, isDirectory: Bool) -> String? {
        guard mode != 0 else { return nil }
        var result = isDirectory ? "d" : "-"
        let triads: [(UInt32, UInt32, UInt32)] = [
            (mode & 0o400, mode & 0o200, mode & 0o100),
            (mode & 0o040, mode & 0o020, mode & 0o010),
            (mode & 0o004, mode & 0o002, mode & 0o001),
        ]
        for (read, write, execute) in triads {
            result += read != 0 ? "r" : "-"
            result += write != 0 ? "w" : "-"
            result += execute != 0 ? "x" : "-"
        }
        return result
    }

    private func describe(_ error: SSHTransportError) -> String {
        switch error {
        case .versionExchange(let detail): "connection closed: version exchange failed — \(detail)"
        case .protocolError(let detail): "protocol error: \(detail)"
        case .negotiation(.noCommonAlgorithm(let category, let offers)):
            "no common \(category) algorithm with the device (it offers: \(offers.joined(separator: ", ")))"
        case .keyExchange(let detail): "key exchange failed: \(detail)"
        case .signature(let detail): "host key signature check failed: \(detail)"
        case .packet(let detail): "packet error: \(detail)"
        case .hostKeyRejected: "the host key was rejected"
        case .hostKeyChangedDuringRekey: "the host key changed during a rekey"
        case .disconnectedByServer(_, let description):
            description.isEmpty ? "the server disconnected" : "the server disconnected: \(description)"
        case .closed: "connection closed"
        }
    }

    private func describe(_ error: UserAuthError) -> String {
        switch error {
        case .protocolError(let detail): "authentication protocol error: \(detail)"
        case .methodInProgress: "authentication method already in flight"
        case .notReady: "authentication started too early"
        case .signer(let detail): "key error: \(detail)"
        case .transport(let detail): describe(detail)
        }
    }

    /// Thread-safe box for values the host-key validator (a @Sendable closure
    /// running inside the pump) needs to hand back to the queue.
    private final class NoticeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _notice: String?
        private var _error: String?

        var notice: String? {
            get { lock.lock(); defer { lock.unlock() }; return _notice }
            set { lock.lock(); defer { lock.unlock() }; _notice = newValue }
        }
        var error: String? {
            get { lock.lock(); defer { lock.unlock() }; return _error }
            set { lock.lock(); defer { lock.unlock() }; _error = newValue }
        }
    }
}
