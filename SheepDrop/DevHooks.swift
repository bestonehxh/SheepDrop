import Foundation

/// Launch arguments the `-demo…` dev hooks may read. Release builds see none:
/// `-demoKnownHosts /dev/null` would switch host-key pinning off and
/// `-demoPassword` puts a password in `ps` output, so they must not ship
/// live (audit 2026-10-02). Tests/run.sh builds Debug, where they work.
nonisolated enum DevHooks {
    static var arguments: [String] {
        #if DEBUG
        CommandLine.arguments
        #else
        []
        #endif
    }
}
