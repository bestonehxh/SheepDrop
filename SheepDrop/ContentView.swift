import AppKit
import SwiftUI

/// App shell, LabDC-style: a 248pt sidebar (Client / Server) and the selected page.
/// No bar across the top; the sidebar is always there. Connections shows the
/// host library page, or — once a host is opened — that host's session view.
struct ContentView: View {
    @ObservedObject private var model = AppModel.shared

    var body: some View {
        HStack(spacing: 0) {
            SidebarView()
                .frame(width: 248)
            Rectangle()
                .fill(Theme.line)
                .frame(width: 1)
            mainColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.background.ignoresSafeArea())
        }
        .frame(minWidth: 1060, minHeight: 640)
        .sheet(isPresented: $model.showQuickConnect) {
            QuickConnectSheet()
        }
        .modifier(FullscreenSync())
        .ignoresSafeArea(.container, edges: .top)
    }

    @ViewBuilder
    private var mainColumn: some View {
        switch model.mainPane {
        case .transfers:
            TransfersView()
        case .serve:
            ServeView()
        case .connection:
            if let tab = model.selectedTab {
                ConnectionView(tab: tab).id(tab.id)
            } else {
                ConnectionsPage()
            }
        }
    }
}

/// Client-mode landing: the host library lives in the sidebar; the main
/// column either shows a session (ConnectionView) or this quiet hint.
struct ConnectionsPage: View {
    @ObservedObject private var model = AppModel.shared

    var body: some View {
        // One hint, no button: "Add Device…" lives at the foot of the sidebar
        // (and File ▸ ⌘T) — a second copy here sat right beside it.
        QuietPage(title: "Devices", scrolls: false) {
            VStack(alignment: .leading, spacing: 10) {
                // A fresh install has one EMPTY default group — count hosts.
                Text(model.groups.allSatisfy(\.hosts.isEmpty) && model.recents.isEmpty
                     ? "No devices yet — use Add Device… at the bottom left (⌘T)."
                     : "Pick a device on the left to open a file session.")
                    .font(Theme.name)
                    .foregroundStyle(Theme.ink)
            }
        }
    }
}
