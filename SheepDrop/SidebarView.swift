import SwiftUI

/// The sidebar with the app's two halves: **Client** (reach out to devices —
/// open sessions, the host library, activity) and **Server** (let devices
/// pull files from this Mac — the three listeners and this Mac's address).
/// One segmented switch at the top, like the original design v2 split.
struct SidebarView: View {
    @ObservedObject private var model = AppModel.shared
    @State private var renameText = ""
    @State private var newGroupText = ""

    var body: some View {
        VStack(spacing: 0) {
            // Traffic-light row (the sidebar owns the titlebar area).
            HStack { Spacer() }
                .frame(height: model.isFullScreen ? 12 : 44)

            tabs
                .padding(.horizontal, 14)
                .padding(.bottom, 4)

            if isServer {
                ServerSidebarBody()
            } else {
                clientBody
            }
        }
        .frame(maxHeight: .infinity)
        .background(Theme.sidebar.ignoresSafeArea())
        // Outline-driven alerts (Rename group / New group).
        .alert("Rename group", isPresented: renameBinding) {
            TextField("Group name", text: $renameText)
            Button("Cancel", role: .cancel) { model.renameGroupRequest = nil }
            Button("Rename") {
                if let id = model.renameGroupRequest {
                    let name = renameText.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty { model.renameGroup(id, to: name) }
                }
                model.renameGroupRequest = nil
            }
        }
        .onChange(of: model.renameGroupRequest) { _, id in
            renameText = model.groups.first { $0.id == id }?.name ?? ""
        }
        .alert("New group", isPresented: $model.pendingNewGroup) {
            TextField("Group name", text: $newGroupText)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                let name = newGroupText.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { model.addGroup(named: name) }
            }
        }
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { model.renameGroupRequest != nil },
                set: { if !$0 { model.renameGroupRequest = nil } })
    }

    // MARK: - Tabs

    private var isServer: Bool { model.mainPane == .serve }

    private var tabs: some View {
        HStack(spacing: 2) {
            // "Client" returns to the open session (if any) — it no longer
            // clears the selected tab (one click back from Activity).
            SegmentButton(title: "Client", selected: !isServer) {
                model.showClient()
            }
            SegmentButton(title: "Server", selected: isServer) {
                model.mainPane = .serve
            }
        }
        .padding(2)
        .background(Theme.track, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    // MARK: - Client body (host library + activity)

    private var clientBody: some View {
        VStack(spacing: 0) {
            SidebarOutline(model: model, recents: model.recents)

            activityRow
                .padding(.horizontal, 8)
                .padding(.top, 6)

            HStack(spacing: 8) {
                Button {
                    model.pendingNewGroup = true
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 15))
                }
                .buttonStyle(QuietIconStyle(size: 36))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Theme.control, lineWidth: 1))
                .help("New Group")
                .accessibilityLabel("New group")

                Button {
                    model.showQuickConnect = true
                } label: {
                    Text("Add Device…")
                }
                .buttonStyle(QuietPrimaryStyle(height: 36, fullWidth: true, size: 14))
                .help("Add a device and connect (⌘T)")
            }
            .padding(EdgeInsets(top: 12, leading: 14, bottom: 16, trailing: 14))
        }
    }

    private var activeTransfers: Int {
        model.tabs.compactMap(\.sftp).filter { $0.transfer != nil }.count
    }

    private var activityRow: some View {
        let selected = model.mainPane == .transfers
        return Button {
            model.mainPane = .transfers
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 16)
                Text("Activity")
                    .font(.system(size: 14, weight: selected ? .semibold : .regular))
                Spacer(minLength: 0)
                if activeTransfers > 0 {
                    Text("\(activeTransfers)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.background)
                        .padding(.horizontal, 6)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(Theme.ink, in: Capsule())
                        .accessibilityLabel("\(activeTransfers) active")
                }
            }
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 8)
            .frame(height: 36)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.sidebarSelection)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help("Transfers in progress and history (⌘2)")
    }
}

// MARK: - Server body (the listeners + this Mac's address)

private struct ServerSidebarBody: View {
    @ObservedObject private var model = AppModel.shared
    /// Shared with ServeView: which listener the Server page shows.
    @AppStorage("serveTransport") private var serveTransport = "tftp"
    /// getifaddrs is a syscall — resolve once, not per render.
    @State private var macIP = LocalNetwork.primaryIPv4() ?? "No network"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GroupLabel(text: "Listeners")
                .padding(EdgeInsets(top: 18, leading: 16, bottom: 6, trailing: 16))
            listenerRow(raw: "tftp", name: "TFTP", running: model.tftpServerRunning,
                        port: model.tftpActualPort.map(Int.init))
            listenerRow(raw: "ssh", name: "SFTP / SCP", running: model.sftpServerRunning,
                        port: model.sftpActualPort.map(Int.init))
            listenerRow(raw: "ftp", name: "FTP", running: model.ftpServerRunning,
                        port: model.ftpActualPort.map(Int.init))

            Spacer(minLength: 12)

            VStack(alignment: .leading, spacing: 3) {
                Text("This Mac on the network:")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.muted)
                Text(macIP)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.ink)
                    .textSelection(.enabled)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.track, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(EdgeInsets(top: 0, leading: 14, bottom: 16, trailing: 14))
            .accessibilityElement(children: .combine)
        }
        .onAppear { macIP = LocalNetwork.primaryIPv4() ?? "No network" }
    }

    private func listenerRow(raw: String, name: String, running: Bool, port: Int?) -> some View {
        let selected = serveTransport == raw
        let state = running ? "Listening · port \(port.map(String.init) ?? "…")" : "Off"
        return Button {
            serveTransport = raw
            model.mainPane = .serve
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(running ? Theme.ok : Theme.control)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(.system(size: 14, weight: selected ? .semibold : .medium))
                        .foregroundStyle(Theme.ink)
                    Text(state)
                        .font(Theme.small)
                        .foregroundStyle(running ? Theme.ok : Theme.muted)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 44)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.sidebarSelection)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .accessibilityLabel("\(name), \(state)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
