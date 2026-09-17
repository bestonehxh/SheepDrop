import AppKit
import SwiftUI

/// Design v2 shell (from the user's chosen design canvas): a fixed 240pt
/// sidebar that owns the traffic-light row, and a main column that shows
/// either a connection (dual pane + transfers drawer), the Transfers
/// screen, or the Serve screen. No tab strip — connections live in the
/// sidebar.
struct ContentView: View {
    @ObservedObject private var model = AppModel.shared

    var body: some View {
        HStack(spacing: 0) {
            // Same as SheepTerm: a full-height column flush with the window
            // edge, painted with the behind-window `.sidebar` material. NOT an
            // inset floating glass panel — its corner radius didn't match the
            // window's, so the traffic lights poked past the panel's edge.
            SidebarView()
                .frame(width: 240)
            Rectangle()
                .fill(Theme.hairline)
                .frame(width: 0.5)
            mainColumn
        }
        // See-through glass for the WHOLE window (user asked for a transparent
        // glass background, 2026-09-17): one behind-window vibrancy layer, and
        // every main-column view leaves its background clear so the desktop
        // shows through. Cards/controls on top use SwiftUI glass.
        .background { VisualEffectBackground(material: .sidebar).ignoresSafeArea() }
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
                EmptyPaneView()
            }
        }
    }
}

struct EmptyPaneView: View {
    @ObservedObject private var model = AppModel.shared

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.up.arrow.down.circle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.faintText)
            Text("SheepDrop")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text("Pick a connection in the sidebar, or press ⌘T.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.dimText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
