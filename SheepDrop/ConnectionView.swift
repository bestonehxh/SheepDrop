import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One open session, as a page: ONE 64 pt header bar (back, host name +
/// status pill, `user@address · PROTO`, Disconnect / close), then the two
/// panes with the Upload / Download buttons between them (the remote side is
/// the blind put/get form for SCP-without-SFTP and TFTP), and a live transfer
/// row only while one runs. Quiet look: no cards, no footer — the status
/// lives in the header.
struct ConnectionView: View {
    @ObservedObject var tab: SessionTab
    @ObservedObject private var model = AppModel.shared
    /// Owned by the tab: as view @StateObject it was recreated on every tab
    /// switch / Transfers / Serve visit, so the local folder snapped back to
    /// ~ and a download landed somewhere other than the folder on screen.
    private var localPane: LocalPaneModel { tab.localPane }
    @State private var localSearch = ""
    @State private var remoteSearch = ""

    private var session: SFTPSession? { tab.sftp }

    var body: some View {
        VStack(spacing: 0) {
            header
            HSplitPanes(tab: tab, localPane: localPane,
                        localSearch: $localSearch, remoteSearch: $remoteSearch)
            if let session { ActiveTransferBar(session: session) }
        }
        .onAppear { tab.sftp?.startIfNeeded() }
        .background {
            // The password sheet MUST be hosted by a view that observes the
            // session. ConnectionView observes only `tab`, so a bare
            // `.sheet(isPresented:)` reading session.needsPassword never
            // re-rendered when the Connect/retry button flipped it — the prompt
            // only appeared when a Keychain or -demoPassword path ALSO changed
            // tab.status and forced a redraw. This zero-size presenter
            // subscribes to the session directly.
            if let session { PasswordSheetPresenter(session: session) }
        }
    }

    // MARK: - Header bar

    private var header: some View {
        // No back button: the device list is always in the sidebar, so "back"
        // only led to an empty hint page.
        QuietHeaderBar(horizontalPadding: 24) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 10) {
                    Text(tab.host.displayName)
                        .font(Theme.pageTitle)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                    StatusPill(text: statusWord, kind: statusKind)
                        .help(failureMessage ?? statusWord)
                }
                Text(headerSubtitle)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 16)
            if isLive {
                Button("Disconnect") { session?.disconnect() }
                    .buttonStyle(.quietBordered)
            }
            IconButton(systemName: "xmark", label: "Close session (⇧⌘W)",
                       size: 32, symbolSize: 14, tint: Theme.muted) {
                model.closeTab(tab)
            }
        }
    }

    private var statusWord: String {
        switch tab.status {
        case .disconnected: "Not connected"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .failed: "Failed"
        }
    }

    private var statusKind: StatusPill.Kind {
        switch tab.status {
        case .disconnected: .neutral
        case .connecting: .busy
        case .connected: .ok
        case .failed: .attention
        }
    }

    private var failureMessage: String? {
        if case .failed(let message) = tab.status { return message }
        return nil
    }

    private var isLive: Bool {
        if case .connected = tab.status { return true }
        return false
    }

    /// `user@address[:port] · PROTO` — the port only when it isn't the
    /// protocol's default.
    private var headerSubtitle: String {
        let host = tab.host
        let port = host.port == host.proto.defaultPort ? "" : ":\(host.port)"
        let who = host.username.isEmpty
            ? "\(host.address)\(port)"
            : "\(host.username)@\(host.address)\(port)"
        return "\(who) · \(host.proto.label)"
    }
}

/// The live transfer row (only while a transfer runs): one line — verb,
/// filename, `done / total · %` — over a thin 4 pt bar.
struct ActiveTransferBar: View {
    @ObservedObject var session: SFTPSession

    var body: some View {
        if let t = session.transfer {
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    Text(t.isUpload ? "Uploading" : "Downloading")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Text(t.name)
                        .font(Theme.detail)
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(readout(t))
                        .font(Theme.detail)
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink)
                    IconButton(systemName: "xmark", label: "Cancel transfer",
                               size: 24, symbolSize: 10, tint: Theme.muted) {
                        session.cancelTransfer()
                    }
                }
                QuietProgressBar(fraction: t.fraction)
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 16)
            .overlay(alignment: .top) {
                Rectangle().fill(Theme.line).frame(height: 1)
            }
            .accessibilityElement(children: .contain)
        }
    }

    private func readout(_ t: SFTPSession.TransferState) -> String {
        if let f = t.fraction {
            return "\(ByteFormat.string(t.done)) / \(ByteFormat.string(t.total)) · \(Int(f * 100))%"
        }
        return ByteFormat.string(t.done)
    }
}

/// Hosts the password sheet from a view that OBSERVES the session, so a
/// `needsPassword` toggle actually presents it (see ConnectionView.body).
private struct PasswordSheetPresenter: View {
    @ObservedObject var session: SFTPSession

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .sheet(isPresented: $session.needsPassword) {
                PasswordPromptSheet(session: session)
            }
    }
}

// MARK: - Panes

private struct HSplitPanes: View {
    @ObservedObject var tab: SessionTab
    @ObservedObject var localPane: LocalPaneModel
    @Binding var localSearch: String
    @Binding var remoteSearch: String

    var body: some View {
        HStack(spacing: 0) {
            LocalPaneView(localPane: localPane, searchText: $localSearch)
                .frame(maxWidth: .infinity)
            if let session = tab.sftp, session.isBrowsable {
                TransferColumn(hostName: tab.host.displayName,
                               canUpload: canUpload, canDownload: canDownload,
                               onUpload: upload, onDownload: download)
                RemoteListPane(tab: tab, session: session, searchText: $remoteSearch)
                    .frame(maxWidth: .infinity)
            } else {
                Spacer().frame(width: 32)
                BlindPane(tab: tab, localPane: localPane)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(EdgeInsets(top: 18, leading: 24, bottom: 12, trailing: 24))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var isConnectedSFTP: Bool {
        guard tab.sftp?.isBrowsable == true, case .connected = tab.status else { return false }
        return tab.sftp?.transfer == nil
    }

    private var selectedLocalFile: URL? {
        guard let name = localPane.selection else { return nil }
        let url = localPane.directoryURL.appendingPathComponent(name)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return nil }
        return url
    }

    private var canUpload: Bool {
        isConnectedSFTP && selectedLocalFile != nil
    }

    private var canDownload: Bool {
        guard isConnectedSFTP, let session = tab.sftp,
              let name = session.selection,
              let entry = session.entries.first(where: { $0.name == name }) else { return false }
        return !entry.isDirectory
    }

    private func upload() {
        guard let url = selectedLocalFile else { return }
        tab.sftp?.upload(localURL: url)
    }

    private func download() {
        guard let session = tab.sftp, let name = session.selection else { return }
        session.download(entryName: name, into: localPane.directoryURL) {
            localPane.reload()
        }
    }
}

/// The narrow column between the panes: → Upload (filled ink when enabled)
/// and ← Download (outlined). These replace the old Put / Get text links.
private struct TransferColumn: View {
    let hostName: String
    let canUpload: Bool
    let canDownload: Bool
    let onUpload: () -> Void
    let onDownload: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Button(action: onUpload) {
                Image(systemName: "arrow.right")
            }
            .buttonStyle(RoundTransferStyle(filled: true))
            .disabled(!canUpload)
            .help(canUpload ? "Upload the selected file to \(hostName)"
                  : "Upload — select a file on this Mac first")
            .accessibilityLabel("Upload to \(hostName)")

            Button(action: onDownload) {
                Image(systemName: "arrow.left")
            }
            .buttonStyle(RoundTransferStyle(filled: false))
            .disabled(!canDownload)
            .help(canDownload ? "Download the selected file to this Mac"
                  : "Download — select a file on \(hostName) first")
            .accessibilityLabel("Download to this Mac")
        }
        .frame(width: 72)
        .frame(maxHeight: .infinity)
    }
}

/// A 44 pt round icon button. Filled = ink disc when enabled; outlined =
/// hairline ring. Disabled = a faint ring either way.
private struct RoundTransferStyle: ButtonStyle {
    let filled: Bool

    func makeBody(configuration: Configuration) -> some View {
        RoundTransferBody(configuration: configuration, filled: filled)
    }
}

private struct RoundTransferBody: View {
    let configuration: ButtonStyleConfiguration
    let filled: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let solid = filled && isEnabled
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(solid ? Theme.background : (isEnabled ? Theme.ink : Theme.faint.opacity(0.6)))
            .frame(width: 44, height: 44)
            .background(Circle().fill(solid ? Theme.ink : Color.clear))
            .overlay {
                if !solid {
                    Circle().strokeBorder(isEnabled ? Theme.ink.opacity(0.55) : Theme.control, lineWidth: 1)
                }
            }
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Circle())
    }
}

/// A pane's header: title, inline path field and its icon buttons, then an
/// optional filter row (revealed by the magnifier button).
private struct PaneHeader<Leading: View, Trailing: View>: View {
    @Binding var searchText: String
    @Binding var showFilter: Bool
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                leading
                trailing
                IconButton(systemName: "line.3.horizontal.decrease", label: showFilter ? "Hide filter" : "Filter",
                           tint: showFilter || !searchText.isEmpty ? Theme.ink : Theme.muted) {
                    showFilter.toggle()
                    if !showFilter { searchText = "" }
                }
            }
            if showFilter || !searchText.isEmpty {
                PaneSearchField(text: $searchText)
            }
        }
        .padding(.leading, 4)
        .padding(.bottom, 10)
    }
}

struct LocalPaneView: View {
    @ObservedObject var localPane: LocalPaneModel
    @Binding var searchText: String
    @State private var showFilter = false

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(searchText: $searchText, showFilter: $showFilter) {
                Text("This Mac")
                    .font(Theme.emphasis)
                    .foregroundStyle(Theme.ink)
                    .fixedSize()
                    .padding(.trailing, 2)
                // Editable address bar: type a path (or `..`) + Enter to cd.
                EditablePathField(path: localPane.displayPath, label: "Mac folder") { localPane.open($0) }
            } trailing: {
                IconButton(systemName: "arrow.up", label: "Parent folder") { localPane.goUp() }
                    .disabled(!localPane.canGoUp)
                IconButton(systemName: "folder", label: "Choose a folder…") { localPane.chooseDirectory() }
            }
            FileColumnHeader(showPerms: false)
            FileListView(
                entries: filtered(localPane.entries, searchText),
                selection: $localPane.selection,
                showPerms: false,
                onOpen: { localPane.enter($0) }
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("This Mac")
    }
}

struct RemoteListPane: View {
    @ObservedObject var tab: SessionTab
    @ObservedObject var session: SFTPSession
    @Binding var searchText: String
    @State private var showFilter = false

    private var isConnected: Bool {
        if case .connected = tab.status { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(searchText: $searchText, showFilter: $showFilter) {
                Circle()
                    .fill(Theme.protoColor(tab.host.proto))
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(tab.host.displayName)
                    .font(Theme.emphasis)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .frame(maxWidth: 160, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.trailing, 2)
                // Editable address bar for the device side: type a remote path
                // (or `..`) + Enter to cd there.
                EditablePathField(path: session.path, label: "Device folder") { session.open($0) }
            } trailing: {
                IconButton(systemName: "arrow.up", label: "Parent folder") { session.goUp() }
                    .disabled(session.path == "/" || !isConnected)
                ZStack {
                    IconButton(systemName: "arrow.clockwise", label: "Refresh") { session.refresh() }
                        .disabled(!isConnected || session.isLoading)
                        .opacity(session.isLoading ? 0 : 1)
                    if session.isLoading {
                        ProgressView().controlSize(.small)
                            .accessibilityLabel("Loading")
                    }
                }
                .frame(width: 28, height: 28)
            }
            // Perms column only when the pane is wide enough — squeezed
            // columns ate the whole Name column at the minimum window size.
            GeometryReader { geo in
                let showPerms = geo.size.width >= 520
                VStack(spacing: 0) {
                    FileColumnHeader(showPerms: showPerms)
                    ZStack {
                        FileListView(
                            entries: filtered(session.entries, searchText),
                            selection: $session.selection,
                            showPerms: showPerms,
                            onOpen: { session.enter($0) }
                        )
                        if !isConnected {
                            RemoteDisconnectedOverlay(tab: tab)
                        }
                    }
                }
            }
            if let notice = session.notice {
                NoticeBar(text: notice) { session.notice = nil }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tab.host.displayName)
    }
}

/// The filter field revealed under a pane header: filled like the path field.
struct PaneSearchField: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.faint)
            TextField("Filter by name", text: $text)
                .textFieldStyle(.plain)
                .font(Theme.body)
                .foregroundStyle(Theme.ink)
                .focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.faint)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear filter")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(Theme.inset, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onAppear { focused = true }
    }
}

private func filtered(_ entries: [FileEntry], _ searchText: String) -> [FileEntry] {
    guard !searchText.isEmpty else { return entries }
    return entries.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
}

/// A path shown in a pane header that doubles as a `cd`-style address bar:
/// a quiet filled field showing the current path; accepts a typed path
/// (absolute, `~`, or relative with `..`) and navigates on Return. Stays in
/// sync with the pane's current path while not being edited.
struct EditablePathField: View {
    let path: String
    var label = "Folder path"
    let onGo: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("path", text: $draft)
            .textFieldStyle(.plain)
            .font(Theme.mono)
            .foregroundStyle(Theme.ink)
            .lineLimit(1)
            .truncationMode(.head)
            .focused($focused)
            .padding(.horizontal, 9)
            .frame(height: 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.inset, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                if focused {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Theme.control, lineWidth: 1)
                }
            }
            .accessibilityLabel(label)
            .help("Type a path and press Return")
            .onSubmit { onGo(draft); focused = false }
            .onChange(of: path) { _, newPath in if !focused { draft = newPath } }
            .onChange(of: focused) { _, isFocused in if !isFocused { draft = path } }
            .onAppear { draft = path }
    }
}

/// A plain pane header row (used by the blind pane, which has no path).
struct PaneStrip<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 8) {
            content
        }
        .padding(.leading, 4)
        .frame(height: 28)
        .padding(.bottom, 10)
    }
}

struct RemoteDisconnectedOverlay: View {
    @ObservedObject var tab: SessionTab

    var body: some View {
        VStack(alignment: .center, spacing: 12) {
            if case .connecting = tab.status {
                ProgressView().controlSize(.small)
                Text("Connecting…")
                    .font(Theme.body)
                    .foregroundStyle(Theme.muted)
            } else {
                Text(hasFailed ? "Couldn’t connect" : "Not connected")
                    .font(Theme.subtitle)
                    .foregroundStyle(Theme.ink)
                if hasFailed {
                    Text(statusText)
                        .font(Theme.detail)
                        .foregroundStyle(Theme.attention)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 340)
                        .textSelection(.enabled)
                }
                Button {
                    tab.sftp?.retry()
                } label: {
                    Text(hasFailed ? "Try Again" : "Connect")
                }
                .buttonStyle(QuietPrimaryStyle(height: 36, size: 14))
                .padding(.top, 4)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(Theme.background.opacity(0.92))
    }

    private var hasFailed: Bool {
        if case .failed = tab.status { return true }
        return false
    }

    private var statusText: String {
        if case .failed(let message) = tab.status { return message }
        return "Not connected"
    }
}

struct NoticeBar: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(text)
                .font(Theme.small)
                .foregroundStyle(Theme.muted)
                .lineLimit(2)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            IconButton(systemName: "xmark", label: "Dismiss", size: 22, symbolSize: 10, tint: Theme.muted, action: dismiss)
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .padding(.vertical, 5)
        .background(Theme.inset, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .padding(.top, 8)
    }
}

// MARK: - Blind pane (SCP without SFTP / TFTP)

struct BlindPane: View {
    @ObservedObject var tab: SessionTab
    @ObservedObject var localPane: LocalPaneModel
    @State private var remoteName = ""
    @State private var feedback: String?
    @State private var feedbackIsError = false

    private var session: SFTPSession? { tab.sftp }
    private var isSCP: Bool { tab.host.proto == .scp }

    var body: some View {
        VStack(spacing: 0) {
            PaneStrip {
                Circle()
                    .fill(Theme.protoColor(tab.host.proto))
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(tab.host.displayName)
                    .font(Theme.emphasis)
                    .foregroundStyle(Theme.ink)
                Text("no folder listing")
                    .font(Theme.small)
                    .foregroundStyle(Theme.faint)
                Spacer(minLength: 0)
                if isSCP { scpStatus }
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.line).frame(height: 1).offset(y: 0)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(blindTitle)
                        .font(Theme.subtitle)
                        .foregroundStyle(Theme.ink)
                    Text(blindBody)
                        .font(Theme.body)
                        .foregroundStyle(Theme.muted)
                        .multilineTextAlignment(.leading)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Remote filename")
                            .font(Theme.groupLabel)
                            .tracking(0.66)
                            .textCase(.uppercase)
                            .foregroundStyle(Theme.muted)
                        TextField(isSCP ? "flash:/image.swi or /var/log/messages"
                            : "ArubaCX-10.13-boot.swi", text: $remoteName)
                            .textFieldStyle(QuietBoxFieldStyle(size: 13))
                            .font(Theme.mono)
                            .accessibilityLabel("Remote filename")
                        HStack(spacing: 10) {
                            Button("Put file") { put() }
                                .buttonStyle(.quietPrimary)
                                .disabled(!canPut)
                                .help("Upload the selected Mac file to the remote filename")
                            Button("Get file") { get() }
                                .buttonStyle(.quietBordered)
                                .disabled(!canGet)
                                .help("Download the remote filename into the Mac folder")
                        }
                        .padding(.top, 4)
                        if let transfer = session?.transfer {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(transferText(transfer))
                                    .font(Theme.small)
                                    .foregroundStyle(Theme.muted)
                            }
                        } else if let feedback {
                            StateText(text: feedback, attention: feedbackIsError)
                        }
                        Text(blindFoot)
                            .font(Theme.small)
                            .foregroundStyle(Theme.muted)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: 420, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var scpStatus: some View {
        switch tab.status {
        case .connecting:
            StateText(text: "Connecting…")
        case .connected:
            EmptyView()
        default:
            Button("Connect…") { session?.retry() }
                .buttonStyle(.quietBorderedSmall)
        }
    }

    private var blindTitle: String {
        isSCP ? "SCP is copy-only" : "TFTP has no directory listing"
    }

    private var blindBody: String {
        isSCP
            ? "This device serves SCP without the SFTP subsystem, so there is nothing to browse. Name the remote file and SheepDrop will PUT the selected local file or GET into the local folder."
            : "RFC 1350 defines only read and write of a named file. Name the file you want — no browsing, no rename, no delete."
    }

    private var blindFoot: String {
        if isSCP {
            let selected = localPane.selection.map { "PUT sends “\($0)”. " } ?? "Select a local file to PUT. "
            return selected + "GET saves into \(localPane.displayPath)."
        }
        return "The TFTP client lands in a later build — use Server mode and let the device pull instead. With blksize 1468 a TFTP file caps at ~96 MB; anything larger goes over SFTP/SCP."
    }

    private var canPut: Bool {
        guard isSCP, isConnected, session?.transfer == nil,
              !remoteName.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return selectedLocalFile != nil
    }

    private var canGet: Bool {
        isSCP && isConnected && session?.transfer == nil
            && !remoteName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var isConnected: Bool {
        if case .connected = tab.status { return true }
        return false
    }

    private var selectedLocalFile: URL? {
        guard let name = localPane.selection else { return nil }
        let url = localPane.directoryURL.appendingPathComponent(name)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return nil }
        return url
    }

    private func put() {
        guard let file = selectedLocalFile, let session else { return }
        feedback = nil
        let target = remoteName.trimmingCharacters(in: .whitespaces)
        session.scpPush(localURL: file, remotePath: target) { error in
            feedbackIsError = error != nil
            feedback = error ?? "Sent \(file.lastPathComponent)"
            AppModel.shared.recordTransfer(
                name: file.lastPathComponent,
                detail: "SCP · \(tab.host.displayName) \(target)",
                isUpload: true, bytes: 0, failed: error != nil)
        }
    }

    private func get() {
        guard let session else { return }
        feedback = nil
        let target = remoteName.trimmingCharacters(in: .whitespaces)
        session.scpPull(remotePath: target, into: localPane.directoryURL) { error in
            feedbackIsError = error != nil
            feedback = error ?? "Saved into \(localPane.displayPath)"
            localPane.reload()
            AppModel.shared.recordTransfer(
                name: (target as NSString).lastPathComponent,
                detail: "SCP · \(tab.host.displayName) → \(localPane.displayPath)",
                isUpload: false, bytes: 0, failed: error != nil)
        }
    }

    private func transferText(_ transfer: SFTPSession.TransferState) -> String {
        if let fraction = transfer.fraction {
            return "\(transfer.name) — \(ByteFormat.string(transfer.done)) / \(ByteFormat.string(transfer.total)) · \(Int(fraction * 100))%"
        }
        return "\(transfer.name) — \(ByteFormat.string(transfer.done))"
    }
}

// MARK: - Transfer rows (Activity page)

struct LiveTransferRow: View {
    @ObservedObject var tab: SessionTab

    var body: some View {
        if let session = tab.sftp, let transfer = session.transfer {
            HStack(spacing: 12) {
                TransferGlyph(isUpload: transfer.isUpload)
                VStack(alignment: .leading, spacing: 2) {
                    Text(transfer.name)
                        .font(Theme.name)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(transfer.isUpload ? "Uploading to" : "Downloading from") \(tab.host.displayName) · \(tab.host.proto.label)")
                        .font(Theme.small)
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
                .frame(minWidth: 200, maxWidth: 300, alignment: .leading)
                QuietProgressBar(fraction: transfer.fraction)
                Text(progressText(transfer))
                    .font(Theme.detail)
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
                    .frame(width: 170, alignment: .trailing)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 12)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.line).frame(height: 1)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func progressText(_ transfer: SFTPSession.TransferState) -> String {
        if let fraction = transfer.fraction {
            // done / total · pct — the total tells the user how big the file is
            // and how far along the transfer is.
            return "\(ByteFormat.string(transfer.done)) / \(ByteFormat.string(transfer.total)) · \(Int(fraction * 100))%"
        }
        // Unknown total (server gave no SIZE): show bytes moved so far.
        return ByteFormat.string(transfer.done)
    }
}

struct HistoryTransferRow: View {
    let record: TransferRecord

    var body: some View {
        HStack(spacing: 12) {
            TransferGlyph(isUpload: record.isUpload, failed: record.failed)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.name)
                    .font(Theme.name)
                    .foregroundStyle(record.failed ? Theme.attention : Theme.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(record.detail)
                    .font(Theme.small)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
            Spacer()
            Text(DateFormat.string(record.finished))
                .font(Theme.detail)
                .monospacedDigit()
                .foregroundStyle(Theme.muted)
            StatusPill(text: record.cancelled ? "Cancelled" : record.failed ? "Failed" : "Done",
                       kind: record.cancelled ? .neutral : record.failed ? .attention : .ok)
                .frame(width: 76, alignment: .trailing)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.line).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The one glyph a transfer row needs, monochrome; failed rows take the
/// attention colour, everything else stays grey.
struct TransferGlyph: View {
    let isUpload: Bool
    var failed = false

    var body: some View {
        Image(systemName: isUpload ? "arrow.up" : "arrow.down")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(failed ? Theme.attention : Theme.muted)
            .frame(width: 22)
            .accessibilityLabel(isUpload ? "Upload" : "Download")
    }
}
