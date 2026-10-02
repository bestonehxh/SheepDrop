import Foundation

/// The one containment rule every built-in server (SFTP, SCP, FTP, TFTP) uses
/// for the served folder.
///
/// A textual prefix check on a standardized path is not enough: a symlink
/// inside the root (`root/link -> /etc`) passes it, and every server then
/// followed the link out (audit 2026-10-02 read /etc/hosts through all four).
/// So the check runs on the REAL path: the deepest part of the candidate that
/// exists is resolved with realpath(3) — symlinks included, a dangling one
/// refused — and the not-yet-existing tail (an upload's new name) is appended.
/// realpath is used rather than `resolvingSymlinksInPath`, which strips
/// `/private` and would make the comparison lie.
nonisolated enum ServedPath {
    /// Returns `candidate` (standardized) if it really lies inside `root`, else nil.
    static func confined(_ candidate: URL, to root: URL) -> URL? {
        let standard = candidate.standardizedFileURL
        guard let realRoot = realPath(root.standardizedFileURL.path) else { return nil }

        var existing = standard.path
        var tail: [String] = []
        // lstat, not stat: a dangling symlink "exists" and must be resolved
        // (and then refused), never treated as a fresh name to create.
        while !lexists(existing) {
            let url = URL(fileURLWithPath: existing)
            let parent = url.deletingLastPathComponent().path
            guard parent != existing else { return nil }
            tail.insert(url.lastPathComponent, at: 0)
            existing = parent
        }
        guard var real = realPath(existing) else { return nil }
        for component in tail {
            guard component != "..", component != "." else { return nil }
            real = (real as NSString).appendingPathComponent(component)
        }
        let prefix = realRoot.hasSuffix("/") ? realRoot : realRoot + "/"
        guard real == realRoot || real.hasPrefix(prefix) else { return nil }
        return standard
    }

    private static func lexists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
