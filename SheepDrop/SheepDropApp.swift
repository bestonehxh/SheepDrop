import SwiftUI

@main
struct SheepDropApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1320, height: 840)
        .commands {
            // Single-window app: AppModel.shared is process-global state, a second
            // window would mirror the first. Same decision as SheepTerm.
            CommandGroup(replacing: .newItem) {
                Button("Add Device…") { AppModel.shared.showQuickConnect = true }
                    .keyboardShortcut("t", modifiers: .command)
                Divider()
                Button("Close Session") {
                    if let tab = AppModel.shared.selectedTab {
                        AppModel.shared.closeTab(tab)
                    }
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
            }
            // The View menu loses the sidebar toggle (the sidebar is fixed and
            // owns the traffic lights) and gains the three pages instead.
            CommandGroup(replacing: .sidebar) {
                Button("Client") { AppModel.shared.showClient() }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Activity") { AppModel.shared.mainPane = .transfers }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Server") { AppModel.shared.mainPane = .serve }
                    .keyboardShortcut("3", modifiers: .command)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // The built-in SSH server writes to POSIX sockets from its own
        // threads; a client that vanishes mid-write must surface EPIPE (which
        // the link turns into a clean error) — not kill the process.
        signal(SIGPIPE, SIG_IGN)
        // Dev hook for screenshot appearance without flipping the system.
        if let index = CommandLine.arguments.firstIndex(of: "-demoAppearance"),
           CommandLine.arguments.indices.contains(index + 1) {
            switch CommandLine.arguments[index + 1] {
            case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
            case "light": NSApp.appearance = NSAppearance(named: .aqua)
            default: break
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
