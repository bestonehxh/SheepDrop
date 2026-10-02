import Foundation
import SheepSSH

// SFTP v3 (draft-ietf-secsh-filexfer-02) client, wire-level and sans-I/O:
// builders return packet payloads the owner sends on the "sftp" subsystem
// channel; `consume` reassembles length-framed responses from the channel's
// data events. One request in flight at a time — the owning worker pumps the
// transport until the reply to the request it just sent arrives, so replies
// are matched by position (their request id is still checked).
//
// Server-side counterpart: SFTPRequestHandler (which serves the same wire
// format to devices connecting in).

enum SFTPProtocolError: Error, Sendable {
    case protocolError(String)
    case status(code: UInt32, message: String)

    var message: String {
        switch self {
        case .protocolError(let message): message
        case .status(_, let message): message.isEmpty ? "server refused the request" : message
        }
    }
}

nonisolated final class SFTPProtocolClient: @unchecked Sendable {
    // SFTP status codes (v3).
    enum Status {
        static let ok: UInt32 = 0
        static let eof: UInt32 = 1
        static let noSuchFile: UInt32 = 2
        static let permissionDenied: UInt32 = 3
        static let failure: UInt32 = 4
        static let opUnsupported: UInt32 = 8
    }

    struct NameEntry {
        var name: String
        var attrs: Attrs
    }

    /// The v3 ATTRS block, reduced to what the file lists need.
    struct Attrs {
        var size: UInt64?
        var permissions: UInt32?
        var mtime: UInt32?
        var type: UInt8?

        static func read(_ r: inout SSHReader) throws(SSHWireError) -> Attrs {
            var attrs = Attrs()
            let flags = try r.readUInt32()
            if flags & 0x1 != 0 { attrs.size = try r.readUInt64() }          // SSH_FILEXFER_ATTR_SIZE
            if flags & 0x2 != 0 {                                            // UIDGID
                _ = try r.readUInt32()
                _ = try r.readUInt32()
            }
            if flags & 0x4 != 0 { attrs.permissions = try r.readUInt32() }   // PERMISSIONS
            if flags & 0x8 != 0 {                                            // ACMODTIME
                _ = try r.readUInt32()
                attrs.mtime = try r.readUInt32()
            }
            if flags & 0x10 != 0 {                                           // EXTENDED
                let count = try r.readUInt32()
                for _ in 0..<count {
                    _ = try r.readString()
                    _ = try r.readString()
                }
            }
            return attrs
        }
    }

    enum Reply {
        case version(UInt32)
        case handle([UInt8])
        case data([UInt8])
        case status(code: UInt32, message: String)
        case names([NameEntry])
        case attrs(Attrs)
    }

    /// Complete responses reassembled from channel data, oldest first.
    private var inbox: [UInt8] = []
    /// Parsed replies with the request id they answer, oldest first.
    private var pendingReplies: [(id: UInt32, reply: Reply)] = []
    private var lastRequestID: UInt32 = 0
    /// Requests sent and not yet answered. Transfers keep several in flight
    /// (pipelining); a reply is accepted only for one of these, so a late
    /// answer to an abandoned request can't be handed to the wrong caller.
    private var outstanding: Set<UInt32> = []
    /// The id of the request built last (the caller just sent it).
    var latestRequestID: UInt32 { lastRequestID }
    private(set) var serverVersion: UInt32 = 0

    // MARK: - Outgoing builders

    func versionPacket() -> [UInt8] {
        lastRequestID = 0
        outstanding.removeAll()
        var w = SSHWriter()
        w.writeByte(1)                          // SSH_FXP_INIT
        w.writeUInt32(3)
        return framed(w.bytes)
    }

    /// SFTP packets are length-framed inside the channel data stream.
    private func framed(_ payload: [UInt8]) -> [UInt8] {
        var out = SSHWriter(capacity: payload.count + 4)
        out.writeUInt32(UInt32(payload.count))
        out.writeBytes(payload)
        return out.bytes
    }

    private func request(_ type: UInt8, _ body: (inout SSHWriter) -> Void = { _ in }) -> [UInt8] {
        lastRequestID &+= 1
        outstanding.insert(lastRequestID)
        var w = SSHWriter()
        w.writeByte(type)
        w.writeUInt32(lastRequestID)
        body(&w)
        return framed(w.bytes)
    }

    func realpathPacket(_ path: String) -> [UInt8] {
        return request(16) { $0.writeString(path) }    // SSH_FXP_REALPATH
    }

    func statPacket(_ path: String) -> [UInt8] {
        return request(17) { $0.writeString(path) }    // SSH_FXP_STAT
    }

    func openReadPacket(_ path: String) -> [UInt8] {
        // pflags: READ.
        return request(3) { w in
            w.writeString(path)
            w.writeUInt32(0x1)
            w.writeUInt32(0)                    // empty attrs
        }
    }

    func openWritePacket(_ path: String, truncate: Bool) -> [UInt8] {
        // pflags: WRITE | CREAT (| TRUNC).
        var flags: UInt32 = 0x2 | 0x8
        if truncate { flags |= 0x10 }
        return request(3) { w in
            w.writeString(path)
            w.writeUInt32(flags)
            w.writeUInt32(0x4)                  // attrs: permissions present
            w.writeUInt32(0o644)
        }
    }

    func readPacket(handle: [UInt8], offset: UInt64, length: Int) -> [UInt8] {
        return request(5) { w in
            w.writeString(handle)
            w.writeUInt64(offset)
            w.writeUInt32(UInt32(length))
        }
    }

    func writePacket(handle: [UInt8], offset: UInt64, _ data: ArraySlice<UInt8>) -> [UInt8] {
        return request(6) { w in
            w.writeString(handle)
            w.writeUInt64(offset)
            w.writeString(data)
        }
    }

    func closePacket(_ handle: [UInt8]) -> [UInt8] {
        return request(4) { $0.writeString(handle) }
    }

    func openDirPacket(_ path: String) -> [UInt8] {
        return request(11) { $0.writeString(path) }
    }

    func readDirPacket(_ handle: [UInt8]) -> [UInt8] {
        return request(12) { $0.writeString(handle) }
    }

    func removePacket(_ path: String) -> [UInt8] {
        return request(13) { $0.writeString(path) }
    }

    func mkdirPacket(_ path: String) -> [UInt8] {
        return request(14) { w in
            w.writeString(path)
            w.writeUInt32(0x4)
            w.writeUInt32(0o755)
        }
    }

    func rmdirPacket(_ path: String) -> [UInt8] {
        return request(15) { $0.writeString(path) }
    }

    func renamePacket(_ from: String, _ to: String) -> [UInt8] {
        return request(18) { w in
            w.writeString(from)
            w.writeString(to)
        }
    }

    // MARK: - Incoming

    /// Feeds channel data; parses every complete reply it can. Returns the
    /// replies that became ready (the owner drains them in order).
    func consume(_ bytes: [UInt8]) throws(SFTPProtocolError) -> [Reply] {
        inbox.append(contentsOf: bytes)
        var replies: [(id: UInt32, reply: Reply)] = []
        do {
            while let reply = try parseOne() {
                replies.append(reply)
            }
        } catch {
            // The stream is out of sync; don't keep the bad bytes around to
            // fail every later request on a tab that still says "connected".
            inbox.removeAll()
            throw error
        }
        pendingReplies.append(contentsOf: replies)
        return replies.map(\.reply)
    }

    /// The next parsed reply, for callers that pump until their own arrives.
    func takeReply() -> Reply? {
        pendingReplies.isEmpty ? nil : pendingReplies.removeFirst().reply
    }

    /// The reply to request `id`, if it has arrived.
    func takeReply(for id: UInt32) -> Reply? {
        guard let index = pendingReplies.firstIndex(where: { $0.id == id }) else { return nil }
        return pendingReplies.remove(at: index).reply
    }

    /// Whatever reply arrived first, with the id it answers (pipelined transfers).
    func takeAnyReply() -> (id: UInt32, reply: Reply)? {
        pendingReplies.isEmpty ? nil : pendingReplies.removeFirst()
    }

    /// Gives up on a request (timed out): its late reply will be dropped.
    func forget(_ id: UInt32) {
        outstanding.remove(id)
        pendingReplies.removeAll { $0.id == id }
    }

    /// Drops any parsed-but-unclaimed replies (the VERSION exchange).
    func drainPending() {
        pendingReplies.removeAll()
    }

    /// Throws when a reply carries a failure status (per-op errors).
    func requireOK(_ reply: Reply, what: String) throws(SFTPProtocolError) {
        switch reply {
        case .status(let code, let message):
            guard code == Status.ok else {
                throw .status(code: code, message: message.isEmpty ? what : message)
            }
        default:
            throw .protocolError("\(what): unexpected reply")
        }
    }

    private func parseOne() throws(SFTPProtocolError) -> (id: UInt32, reply: Reply)? {
        guard inbox.count >= 4 else { return nil }
        let length = (UInt32(inbox[0]) << 24) | (UInt32(inbox[1]) << 16)
            | (UInt32(inbox[2]) << 8) | UInt32(inbox[3])
        // A hostile length must not grow the buffer without bound: the largest
        // legal v3 response is a NAME with many entries, well under 4 MiB.
        guard length >= 1, length <= 4 << 20 else {
            throw .protocolError("sftp reply length \(length) out of range")
        }
        guard inbox.count >= 4 + Int(length) else { return nil }
        let payload = Array(inbox[4..<(4 + Int(length))])
        inbox.removeFirst(4 + Int(length))

        guard let type = payload.first else { throw .protocolError("empty sftp reply") }
        var r = SSHReader(payload, from: 1)
        do {
            // VERSION's first field is the server's version, not a request id.
            if type == 2 {
                serverVersion = try r.readUInt32()
                return (0, .version(serverVersion))
            }
            let id = try r.readUInt32()
            guard id != 0, id <= lastRequestID else {
                throw SFTPProtocolError.protocolError("sftp reply for unsent request \(id)")
            }
            // Only a reply to a request still awaited belongs to anyone. A
            // late reply to an abandoned request (e.g. a stat that timed out)
            // used to be handed to the next caller, and every reply after it
            // was then off by one.
            guard outstanding.remove(id) != nil else { return try parseOne() }
            switch type {
            case 102:                               // SSH_FXP_HANDLE
                return (id, .handle(try r.readString()))
            case 103:                               // SSH_FXP_DATA
                return (id, .data(try r.readString()))
            case 101:                               // SSH_FXP_STATUS
                let code = try r.readUInt32()
                let message = (try? r.readUTF8()) ?? ""
                return (id, .status(code: code, message: message))
            case 104:                               // SSH_FXP_NAME
                let count = Int(try r.readUInt32())
                var entries: [NameEntry] = []
                for _ in 0..<count {
                    let name = try r.readUTF8()
                    _ = try r.readUTF8()            // longname
                    entries.append(NameEntry(name: name, attrs: try Attrs.read(&r)))
                }
                return (id, .names(entries))
            case 105:                               // SSH_FXP_ATTRS
                return (id, .attrs(try Attrs.read(&r)))
            default:
                throw SFTPProtocolError.protocolError("unexpected sftp reply type \(type)")
            }
        } catch {
            throw SFTPProtocolError.protocolError("malformed sftp reply type \(type)")
        }
    }
}
