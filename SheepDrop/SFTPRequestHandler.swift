import Foundation
import SheepSSH

// Serves one client's SFTP requests against a rooted folder. Runs entirely on
// its connection's worker thread (see SFTPServerListener). Implements the
// subset a network device needs: realpath, stat, opendir/readdir, and
// open/read/write/close — enough to list, pull firmware, and (when writes
// are allowed) receive a config backup.
//
// The wire plumbing is SheepDrop's own (length-framed packets inside the
// "sftp" subsystem channel, SheepSSH's SSHReader/SSHWriter); before libssh
// was removed, sftp_get_client_message/sftp_reply_* did this part. The
// filesystem policy below — root confinement, temp-then-promote writes,
// progress throttling — is unchanged.

nonisolated final class SFTPRequestHandler {
    /// Per-open state (a directory cursor, or a file being read/written).
    private final class OpenHandle {
        enum Kind {
            case directory(entries: [URL], index: Int)
            case file(FileHandle, isWrite: Bool)
        }
        var kind: Kind
        let name: String
        var bytes: Int64 = 0
        var total: Int64 = 0
        var lastReported: Int64 = 0
        /// Write handles stream into `tempURL`; CLOSE promotes it to `finalURL`.
        var tempURL: URL?
        var finalURL: URL?
        init(kind: Kind, name: String) { self.kind = kind; self.name = name }
    }

    private let root: URL
    private let allowWrites: @Sendable () -> Bool
    private let peer: String
    private let onLog: @Sendable (TFTPLogEntry) -> Void
    private let onProgress: ServeProgress
    private let token = UUID().uuidString
    /// Handles the client holds. A client that vanishes without CLOSE would
    /// leak one open fd per handle — `closeAll()` (on connection teardown)
    /// releases them, failing their transfer bars.
    private var handles: [[UInt8]: OpenHandle] = [:]

    /// SFTP v3 status codes.
    private enum FX {
        static let ok: UInt32 = 0
        static let eof: UInt32 = 1
        static let noSuchFile: UInt32 = 2
        static let permissionDenied: UInt32 = 3
        static let failure: UInt32 = 4
        static let opUnsupported: UInt32 = 8
    }

    init(root: URL, allowWrites: @escaping @Sendable () -> Bool,
         peer: String, onLog: @escaping @Sendable (TFTPLogEntry) -> Void,
         onProgress: @escaping ServeProgress = { _ in }) {
        self.root = root.standardizedFileURL
        self.allowWrites = allowWrites
        self.peer = peer
        self.onLog = onLog
        self.onProgress = onProgress
    }

    // MARK: - Wire replies

    private func status(_ id: UInt32, _ code: UInt32, _ message: String?) -> [UInt8] {
        var w = SSHWriter()
        w.writeByte(101)                        // SSH_FXP_STATUS
        w.writeUInt32(id)
        w.writeUInt32(code)
        w.writeString(message ?? "ok")
        w.writeString("en")
        return framed(w.bytes)
    }

    private func handleReply(_ id: UInt32, _ handle: [UInt8]) -> [UInt8] {
        var w = SSHWriter()
        w.writeByte(102)                        // SSH_FXP_HANDLE
        w.writeUInt32(id)
        w.writeString(handle)
        return framed(w.bytes)
    }

    private func dataReply(_ id: UInt32, _ data: [UInt8]) -> [UInt8] {
        var w = SSHWriter()
        w.writeByte(103)                        // SSH_FXP_DATA
        w.writeUInt32(id)
        w.writeString(data)
        return framed(w.bytes)
    }

    private func attrsReply(_ id: UInt32, attrs: (size: UInt64, isDir: Bool, mtime: UInt32)) -> [UInt8] {
        var w = SSHWriter()
        w.writeByte(105)                        // SSH_FXP_ATTRS
        w.writeUInt32(id)
        w.writeUInt32(0x1 | 0x2 | 0x4 | 0x8)    // SIZE | UIDGID | PERMISSIONS | ACMODTIME
        w.writeUInt64(attrs.size)
        w.writeUInt32(0)                        // uid
        w.writeUInt32(0)                        // gid
        w.writeUInt32(attrs.isDir ? 0o040755 : 0o100644)
        w.writeUInt32(attrs.mtime)              // atime
        w.writeUInt32(attrs.mtime)              // mtime
        return framed(w.bytes)
    }

    private func nameReply(_ id: UInt32, entries: [(url: URL, name: String)]) -> [UInt8] {
        var w = SSHWriter()
        w.writeByte(104)                        // SSH_FXP_NAME
        w.writeUInt32(id)
        w.writeUInt32(UInt32(entries.count))
        for entry in entries {
            w.writeString(entry.name)
            w.writeString(Self.longname(for: entry.url, name: entry.name))
            let values = try? entry.url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            let isDir = values?.isDirectory ?? false
            w.writeUInt32(0x1 | 0x2 | 0x4 | 0x8)  // SIZE | UIDGID | PERMISSIONS | ACMODTIME
            w.writeUInt64(UInt64(values?.fileSize ?? 0))
            w.writeUInt32(0); w.writeUInt32(0)
            w.writeUInt32(isDir ? 0o040755 : 0o100644)
            let mtime = UInt32((values?.contentModificationDate ?? Date()).timeIntervalSince1970)
            w.writeUInt32(mtime); w.writeUInt32(mtime)
        }
        return framed(w.bytes)
    }

    private func framed(_ payload: [UInt8]) -> [UInt8] {
        var out = SSHWriter(capacity: payload.count + 4)
        out.writeUInt32(UInt32(payload.count))
        out.writeBytes(payload)
        return out.bytes
    }

    // MARK: - Request loop

    /// Handles one inbound SFTP packet (already length-unframed by the
    /// listener's pump) and returns the replies to send on the channel.
    func respond(to payload: [UInt8]) -> [UInt8] {
        guard let type = payload.first else { return [] }
        var r = SSHReader(payload, from: 1)
        // SSH_FXP_INIT has no request id — its first field IS the client's
        // version. Answer with our version before anything else can come.
        if type == 1 {
            _ = try? r.readUInt32()
            var w = SSHWriter()
            w.writeByte(2)                      // SSH_FXP_VERSION
            w.writeUInt32(3)
            return framed(w.bytes)
        }
        guard let id = try? r.readUInt32() else { return [] }
        switch type {
        case 16: return replyRealpath(id, &r)   // SSH_FXP_REALPATH
        case 7, 17: return replyStat(id, &r)    // LSTAT / STAT
        case 8: return replyFStat(id, &r)       // SSH_FXP_FSTAT
        case 11: return openDir(id, &r)         // SSH_FXP_OPENDIR
        case 12: return readDir(id, &r)         // SSH_FXP_READDIR
        case 3: return openFile(id, &r)         // SSH_FXP_OPEN
        case 5: return readFile(id, &r)         // SSH_FXP_READ
        case 6: return writeFile(id, &r)        // SSH_FXP_WRITE
        case 4: return closeHandle(id, &r)      // SSH_FXP_CLOSE
        case 9, 10:                             // SETSTAT / FSETSTAT — accept, ignore
            return status(id, FX.ok, nil)
        case 13, 14, 15, 18:                    // REMOVE / MKDIR / RMDIR / RENAME
            return status(id, FX.opUnsupported, "not supported")
        default:
            return status(id, FX.opUnsupported, "not supported")
        }
    }

    /// Releases every handle the client never closed (its fd goes back, the
    /// interrupted transfer's bar fails, partial temps are dropped).
    func closeAll() {
        for box in handles.values {
            if case .file(let file, let isWrite) = box.kind {
                try? file.close()
                if let temp = box.tempURL { try? FileManager.default.removeItem(at: temp) }
                onProgress(ServeTransfer(token: token, peer: peer, name: box.name, isUpload: isWrite,
                                         done: box.bytes, total: max(box.total, box.bytes),
                                         state: .failed))
            }
        }
        handles.removeAll()
    }

    // MARK: - Path safety

    /// Resolves an SFTP path (client-absolute, rooted at the served folder)
    /// to a real URL, refusing anything that escapes the root.
    private func resolve(_ sftpPath: String) -> URL? {
        var path = sftpPath
        if path.isEmpty || path == "." { path = "/" }
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let candidate = root.appendingPathComponent(trimmed).standardizedFileURL
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        if candidate.path == root.path || candidate.path.hasPrefix(rootPath) {
            return ServedPath.confined(candidate, to: root)     // symlinks too
        }
        return nil
    }

    /// Client-facing absolute path for a real URL under the root.
    private func virtualPath(for url: URL) -> String {
        let rel = url.path.dropFirst(root.path.count)
        let s = String(rel)
        return s.isEmpty ? "/" : (s.hasPrefix("/") ? s : "/" + s)
    }

    private func attributes(for url: URL) -> (size: UInt64, isDir: Bool, mtime: UInt32) {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
        let isDir = values?.isDirectory ?? false
        return (UInt64(values?.fileSize ?? 0), isDir,
                UInt32((values?.contentModificationDate ?? Date()).timeIntervalSince1970))
    }

    // MARK: - Handlers

    private func replyRealpath(_ id: UInt32, _ r: inout SSHReader) -> [UInt8] {
        let requested = (try? r.readUTF8()) ?? ""
        guard let url = resolve(requested) else {
            return status(id, FX.noSuchFile, "no such path")
        }
        let vpath = virtualPath(for: url)
        let attrs = attributes(for: url)
        let w = nameReply(id, entries: [(url, vpath)])
        _ = attrs
        return w
    }

    private func replyStat(_ id: UInt32, _ r: inout SSHReader) -> [UInt8] {
        let requested = (try? r.readUTF8()) ?? ""
        guard let url = resolve(requested),
              FileManager.default.fileExists(atPath: url.path) else {
            return status(id, FX.noSuchFile, "no such file")
        }
        return attrsReply(id, attrs: attributes(for: url))
    }

    private func replyFStat(_ id: UInt32, _ r: inout SSHReader) -> [UInt8] {
        let raw = (try? r.readString()) ?? []
        guard let box = handles[raw] else {
            return status(id, FX.failure, "bad handle")
        }
        let url = root.appendingPathComponent(box.name)
        return attrsReply(id, attrs: attributes(for: url))
    }

    private func openDir(_ id: UInt32, _ r: inout SSHReader) -> [UInt8] {
        let requested = (try? r.readUTF8()) ?? ""
        guard let url = resolve(requested) else {
            return status(id, FX.noSuchFile, "no such directory")
        }
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        let sorted = entries.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let handle = Self.newHandle()
        handles[handle] = OpenHandle(kind: .directory(entries: sorted, index: 0),
                                     name: virtualPath(for: url))
        return handleReply(id, handle)
    }

    private func readDir(_ id: UInt32, _ r: inout SSHReader) -> [UInt8] {
        let raw = (try? r.readString()) ?? []
        guard let box = handles[raw],
              case .directory(let entries, let index) = box.kind else {
            return status(id, FX.failure, "bad handle")
        }
        if index >= entries.count {
            return status(id, FX.eof, nil)
        }
        let end = min(index + 50, entries.count)
        var batch: [(url: URL, name: String)] = []
        for i in index..<end {
            batch.append((entries[i], entries[i].lastPathComponent))
        }
        box.kind = .directory(entries: entries, index: end)
        return nameReply(id, entries: batch)
    }

    private func openFile(_ id: UInt32, _ r: inout SSHReader) -> [UInt8] {
        let requested = (try? r.readUTF8()) ?? ""
        let flags = (try? r.readUInt32()) ?? 0
        _ = (try? r.readUInt32()) ?? 0          // attrs flags (ignored)
        let wantsWrite = flags & 0x2 != 0       // SSH_FXF_WRITE
        guard let url = resolve(requested) else {
            return status(id, FX.noSuchFile, "no such file")
        }
        if wantsWrite {
            guard allowWrites() else {
                log(isWrite: true, name: virtualPath(for: url), detail: "rejected (writes off)", failed: true)
                return status(id, FX.permissionDenied, "writes are disabled")
            }
            let fm = FileManager.default
            var isDir: ObjCBool = false
            let exists = fm.fileExists(atPath: url.path, isDirectory: &isDir)
            guard url.path != root.path, !(exists && isDir.boolValue) else {
                return status(id, FX.failure, "is a directory")
            }
            // Stream into a hidden temp next to the target and promote it on
            // CLOSE — writing in place truncated the existing file up front and
            // left a half-written backup if the device dropped mid-transfer.
            // Without TRUNC the client may write at offsets into the existing
            // content, so seed the temp with a copy of it.
            let temp = url.deletingLastPathComponent()
                .appendingPathComponent(".sheepdrop-sftp-\(UUID().uuidString)")
            if exists && flags & 0x10 == 0 {
                try? fm.copyItem(at: url, to: temp)
            }
            if !fm.fileExists(atPath: temp.path) {
                fm.createFile(atPath: temp.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: temp) else {
                try? fm.removeItem(at: temp)
                return status(id, FX.failure, "cannot open for writing")
            }
            let box = OpenHandle(kind: .file(handle, isWrite: true), name: virtualPath(for: url))
            box.tempURL = temp
            box.finalURL = url
            log(isWrite: true, name: box.name, detail: "receiving", failed: false)
            let handleBytes = Self.newHandle()
            handles[handleBytes] = box
            return handleReply(id, handleBytes)
        } else {
            guard let handle = try? FileHandle(forReadingFrom: url) else {
                return status(id, FX.noSuchFile, "no such file")
            }
            let box = OpenHandle(kind: .file(handle, isWrite: false), name: virtualPath(for: url))
            let sz = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
            box.total = Int64(sz ?? 0)
            log(isWrite: false, name: box.name, detail: "serving", failed: false)
            let handleBytes = Self.newHandle()
            handles[handleBytes] = box
            return handleReply(id, handleBytes)
        }
    }

    private func readFile(_ id: UInt32, _ r: inout SSHReader) -> [UInt8] {
        let raw = (try? r.readString()) ?? []
        let offset = (try? r.readUInt64()) ?? 0
        let requested = Int((try? r.readUInt32()) ?? 0)
        guard let box = handles[raw],
              case .file(let handle, false) = box.kind else {
            return status(id, FX.failure, "bad handle")
        }
        // `len` is client-chosen (up to 4 GB): unclamped it forced a huge
        // allocation. Short reads are legal SFTP — clients ask again.
        let length = min(requested, 256 * 1024)
        do {
            try handle.seek(toOffset: offset)
            let data = try handle.read(upToCount: length) ?? Data()
            if data.isEmpty {
                return status(id, FX.eof, nil)
            }
            box.bytes = max(box.bytes, Int64(offset) + Int64(data.count))
            reportProgress(box, isUpload: false)
            return dataReply(id, Array(data))
        } catch {
            return status(id, FX.failure, "read failed")
        }
    }

    private func writeFile(_ id: UInt32, _ r: inout SSHReader) -> [UInt8] {
        let raw = (try? r.readString()) ?? []
        let offset = (try? r.readUInt64()) ?? 0
        let data = (try? r.readString()) ?? []
        guard let box = handles[raw],
              case .file(let handle, true) = box.kind else {
            return status(id, FX.failure, "bad handle")
        }
        // A zero-length write is protocol-legal; just acknowledge it.
        guard !data.isEmpty else {
            return status(id, FX.ok, nil)
        }
        do {
            try handle.seek(toOffset: offset)
            try handle.write(contentsOf: Data(data))
            box.bytes = max(box.bytes, Int64(offset) + Int64(data.count))
            reportProgress(box, isUpload: true)
            return status(id, FX.ok, nil)
        } catch {
            return status(id, FX.failure, "write failed")
        }
    }

    private func closeHandle(_ id: UInt32, _ r: inout SSHReader) -> [UInt8] {
        let raw = (try? r.readString()) ?? []
        guard let box = handles.removeValue(forKey: raw) else {
            return status(id, FX.ok, nil)
        }
        if case .file(let file, let isWrite) = box.kind {
            try? file.close()
            if let temp = box.tempURL, let final = box.finalURL, !promote(temp, to: final) {
                log(isWrite: true, name: box.name, detail: "could not save", failed: true)
                onProgress(ServeTransfer(token: token, peer: peer, name: box.name, isUpload: true,
                                         done: box.bytes, total: max(box.total, box.bytes),
                                         state: .failed))
                return status(id, FX.failure, "write failed")
            }
            // A read closed before the end (the client cancelled or only
            // wanted the head) is NOT "sent" — it showed a green "Sent … 5%".
            let partial = !isWrite && box.total > 0 && box.bytes < box.total
            if isWrite { log(isWrite: true, name: box.name, detail: "received", failed: false) }
            else if partial {
                log(isWrite: false, name: box.name,
                    detail: "stopped at \(ByteFormat.string(box.bytes))", failed: true)
            } else { log(isWrite: false, name: box.name, detail: "sent", failed: false) }
            // Keep the transfer as a history row (the finalizing
            // onProgress(nil) leaves a .done/.failed in place).
            onProgress(ServeTransfer(token: token, peer: peer, name: box.name, isUpload: isWrite,
                                     done: box.bytes, total: max(box.total, box.bytes),
                                     state: partial ? .failed : .done))
        }
        return status(id, FX.ok, nil)
    }

    private func promote(_ temp: URL, to final: URL) -> Bool {
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: final.path) {
                _ = try fm.replaceItemAt(final, withItemAt: temp)
            } else {
                try fm.moveItem(at: temp, to: final)
            }
            return true
        } catch {
            try? fm.removeItem(at: temp)
            return false
        }
    }

    private func reportProgress(_ box: OpenHandle, isUpload: Bool) {
        if box.bytes - box.lastReported >= 128 * 1024 || (box.total > 0 && box.bytes >= box.total) {
            box.lastReported = box.bytes
            onProgress(ServeTransfer(token: token, peer: peer, name: box.name, isUpload: isUpload,
                                     done: box.bytes, total: box.total))
        }
    }

    private static func newHandle() -> [UInt8] {
        var rng = SystemRandomNumberGenerator()
        return (0..<8).map { _ in UInt8.random(in: 0...255, using: &rng) }
    }

    private static func longname(for url: URL, name: String) -> String {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        let isDir = values?.isDirectory ?? false
        let perms = isDir ? "drwxr-xr-x" : "-rw-r--r--"
        let size = values?.fileSize ?? 0
        return String(format: "%@ 1 sheepdrop sheepdrop %9d Jan 1 00:00 %@", perms, size, name)
    }

    private func log(isWrite: Bool, name: String, detail: String, failed: Bool) {
        onLog(TFTPLogEntry(time: Date(), peer: peer, isWrite: isWrite,
                           filename: name, detail: "SFTP · " + detail, failed: failed))
    }
}
