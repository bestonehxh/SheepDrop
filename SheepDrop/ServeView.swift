import AppKit
import SwiftUI

/// The Server page: let a switch, firewall or router pull files from this
/// Mac. The sidebar picks the listener (TFTP / SFTP-SCP / FTP); this page is
/// one flow for it — a 64 pt header (title, status pill, "Server on"
/// switch), then two columns without cards, sections split by hairlines:
/// left = where devices reach this Mac + settings, right = the live/held
/// transfer + the request log as a table. Still NO copy-command builder —
/// only the base address (see CLAUDE.md).
struct ServeView: View {
    @ObservedObject private var model = AppModel.shared
    @AppStorage("tftpAllowWrites") private var allowWrites = false
    @AppStorage("serveTransport") private var transport = ServeTransport.tftp.rawValue
    @State private var sftpPasswordDraft = ""
    /// getifaddrs is a syscall — resolve the Mac's IP once, not per body render.
    @State private var macIP = LocalNetwork.primaryIPv4() ?? "no network"

    /// SFTP and SCP are one SSH server, so they are a single choice
    /// ("SFTP / SCP"); TFTP and FTP are their own servers.
    enum ServeTransport: String {
        case tftp, ssh, ftp
        var label: String {
            switch self {
            case .tftp: "TFTP"
            case .ssh: "SFTP / SCP"
            case .ftp: "FTP"
            }
        }
        var usesSSHServer: Bool { self == .ssh }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                HStack(alignment: .top, spacing: 40) {
                    VStack(alignment: .leading, spacing: 24) {
                        reachSection
                        settingsSection
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    VStack(alignment: .leading, spacing: 24) {
                        transferSection
                        logSection
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .padding(EdgeInsets(top: 24, leading: 32, bottom: 24, trailing: 32))
                .frame(maxWidth: Theme.maxContentWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Theme.background)
    }

    private var isTFTP: Bool { currentTransport == .tftp }
    private var usesSSHServer: Bool { currentTransport.usesSSHServer }

    // MARK: - Header

    private var header: some View {
        QuietHeaderBar {
            Text("\(currentTransport.label) server")
                .font(Theme.pageTitle)
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            StatusPill(text: transportStatus, kind: selectedRunning ? .ok : .neutral)
            Spacer(minLength: 16)
            Toggle(isOn: transportRunningBinding) {
                Text("Server on")
                    .font(Theme.body)
                    .foregroundStyle(Theme.muted)
            }
            .toggleStyle(.quiet)
            .fixedSize()
            .accessibilityLabel("\(currentTransport.label) server on")
        }
    }

    private var transportStatus: String {
        switch currentTransport {
        case .tftp:
            if model.tftpServerRunning, let port = model.tftpActualPort {
                return "Listening · port \(port)"
            }
            return "Off"
        case .ssh:
            if model.sftpServerRunning, let port = model.sftpActualPort {
                return "Listening · port \(port)"
            }
            return "Off"
        case .ftp:
            if model.ftpServerRunning, let port = model.ftpActualPort {
                return "Listening · port \(port)"
            }
            return "Off"
        }
    }

    private var transportRunningBinding: Binding<Bool> {
        switch currentTransport {
        case .tftp: return tftpRunningBinding
        case .ssh: return sftpRunningBinding
        case .ftp: return Binding(get: { model.ftpServerRunning }, set: { model.setFTPServer(on: $0) })
        }
    }

    private var transportStartError: String? {
        switch currentTransport {
        case .tftp: return model.tftpStartError
        case .ssh: return model.sftpStartError
        case .ftp: return model.ftpStartError
        }
    }

    // MARK: - Left column: reach address + settings

    /// The base URL a device uses to reach this Mac — the user appends their
    /// own filename and destination. One address, one Copy, no builder.
    private var reachSection: some View {
        QuietSection(title: "Devices reach this Mac at") {
            HStack(spacing: 8) {
                Text(reachURL)
                    .font(.system(size: 15, design: .monospaced))
                    .foregroundStyle(selectedRunning ? Theme.ink : Theme.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.sidebar, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                CopyButton(value: reachURL, prominent: true)
            }
            if !selectedRunning {
                QuietNote("The server is off — turn it on (top right) before running the copy command on the device.")
            }
            if let error = transportStartError {
                QuietNote(error, attention: true)
            }
            Text(protocolHint)
                .font(Theme.detail)
                .foregroundStyle(Theme.muted)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var protocolHint: String {
        switch currentTransport {
        case .tftp:
            return "No login, UDP port 69. Simplest and most widely supported; anyone on the segment can read the folder — use on a trusted path."
        case .ssh:
            return "scp:// works on the same port and login. Port 22 (falls back to 2222 if the Mac's Remote Login owns 22); `copy scp:` on switches always uses 22."
        case .ftp:
            return "Port 21 (falls back to 2121). CLEARTEXT — the password and files cross the network unencrypted, so prefer SFTP unless the device only speaks FTP. Shares the SFTP login."
        }
    }

    private var reachURL: String {
        let ip = macIP == "no network" ? "<mac-ip>" : macIP
        switch currentTransport {
        case .tftp:
            let port = model.tftpActualPort
            let suffix = (port == nil || port == 69) ? "" : ":\(port!)"
            return "tftp://\(ip)\(suffix)/"
        case .ssh:
            let port = model.sftpActualPort ?? AppModel.sftpServerPort
            let suffix = port == 22 ? "" : ":\(port)"
            return "sftp://\(model.sftpUsername)@\(ip)\(suffix)/"
        case .ftp:
            let port = model.ftpActualPort ?? AppModel.ftpServerPort
            let suffix = port == 21 ? "" : ":\(port)"
            return "ftp://\(model.sftpUsername)@\(ip)\(suffix)/"
        }
    }

    private var needsLogin: Bool { currentTransport == .ssh || currentTransport == .ftp }

    private var settingsSection: some View {
        QuietSection(title: "Settings", divider: false) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    settingLabel("Served folder")
                    HStack(spacing: 8) {
                        Text((model.tftpRootPath as NSString).abbreviatingWithTildeInPath)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Change…") { chooseRoot() }
                            .buttonStyle(.quietBorderedSmall)
                        Button("Show") {
                            let url = URL(fileURLWithPath: model.tftpRootPath)
                            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                            NSWorkspace.shared.open(url)
                        }
                        .buttonStyle(.quietBorderedSmall)
                        .help("Open the served folder in Finder")
                    }
                }
                if needsLogin {
                    GridRow {
                        settingLabel("Username")
                        TextField("sheepdrop", text: usernameBinding)
                            .textFieldStyle(.quietBox)
                            .frame(maxWidth: 260)
                            .disabled(credentialsLocked)
                            .accessibilityLabel("Server username")
                    }
                    GridRow {
                        settingLabel("Password")
                        HStack(spacing: 8) {
                            SecureField(model.sftpServerPassword.isEmpty ? "Set a password" : "••••••••",
                                        text: $sftpPasswordDraft)
                                .textFieldStyle(.quietBox)
                                .frame(maxWidth: 260)
                                .disabled(credentialsLocked)
                                .accessibilityLabel("Server password")
                            Button("Save") {
                                model.setSFTPPassword(sftpPasswordDraft)
                                sftpPasswordDraft = ""
                            }
                            .buttonStyle(.quietBorderedSmall)
                            .disabled(credentialsLocked || sftpPasswordDraft.isEmpty)
                        }
                    }
                    if credentialsLocked {
                        GridRow {
                            Color.clear.frame(width: 1, height: 1)
                            QuietNote("Turn the SFTP and FTP servers off to change the login.")
                        }
                    }
                }
                GridRow {
                    settingLabel("Writes")
                    Toggle("Allow devices to upload (config backups)", isOn: $allowWrites)
                        .toggleStyle(.checkbox)
                        .font(Theme.body)
                        .tint(Theme.ink)
                }
            }
        }
    }

    private func settingLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13.5))
            .foregroundStyle(Theme.muted)
            .frame(width: 110, alignment: .leading)
            .gridColumnAlignment(.leading)
    }

    /// The FTP server shares the SSH virtual login, so editing credentials
    /// while EITHER server is up would desync what a running server accepts
    /// from what the reach-URL shows.
    private var credentialsLocked: Bool {
        model.sftpServerRunning || model.ftpServerRunning
    }

    private var selectedRunning: Bool {
        switch currentTransport {
        case .tftp: model.tftpServerRunning
        case .ssh: model.sftpServerRunning
        case .ftp: model.ftpServerRunning
        }
    }

    private var tftpRunningBinding: Binding<Bool> {
        Binding(get: { model.tftpServerRunning }, set: { model.setTFTPServer(on: $0) })
    }

    private var sftpRunningBinding: Binding<Bool> {
        Binding(get: { model.sftpServerRunning }, set: { model.setSFTPServer(on: $0) })
    }

    private var usernameBinding: Binding<String> {
        Binding(get: { model.sftpUsername }, set: { model.setSFTPUsername($0) })
    }

    private var currentTransport: ServeTransport {
        ServeTransport(rawValue: transport) ?? .tftp
    }

    // MARK: - Right column: transfer + request log

    /// The transfer a device is running (or just finished) on any built-in
    /// server. A completed transfer is KEPT as a held row until the next
    /// transfer or until every server stops.
    private var transferSection: some View {
        QuietSection(title: "Transfer") {
            if let peer = model.activeServeTransfer?.peer {
                Text(peer)
                    .font(Theme.detail)
                    .foregroundStyle(Theme.muted)
                    .textSelection(.enabled)
            }
        } content: {
            if let t = model.activeServeTransfer {
                transferRow(t)
            } else {
                Text("No transfer yet — it appears here when a device pulls or pushes a file.")
                    .font(Theme.detail)
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: model.activeServeTransfer)
    }

    @ViewBuilder
    private func transferRow(_ t: ServeTransfer) -> some View {
        let fraction = t.total > 0 ? min(max(Double(t.done) / Double(t.total), 0), 1) : 0
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                // State as words: Sending / Sent / Receiving / Received / Failed.
                Text(barLabel(t))
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(barTint(t))
                Text(t.name)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(readout(t))
                    .font(.system(size: 13.5))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
            }
            switch t.state {
            case .active:
                QuietProgressBar(fraction: t.total > 0 ? fraction : nil, height: 6)
            case .done:
                QuietProgressBar(fraction: 1, height: 6, tint: Theme.ok)
            case .failed:
                QuietProgressBar(fraction: fraction, height: 6, tint: Theme.attention)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func barTint(_ t: ServeTransfer) -> Color {
        switch t.state {
        case .done: return Theme.ok
        case .failed: return Theme.attention
        case .active: return Theme.ink
        }
    }

    private func barLabel(_ t: ServeTransfer) -> String {
        switch t.state {
        case .active: return t.isUpload ? "Receiving" : "Sending"
        case .done: return t.isUpload ? "Received" : "Sent"
        case .failed: return "Failed"
        }
    }

    private func readout(_ t: ServeTransfer) -> String {
        if t.total > 0 {
            let pct = Int((Double(t.done) / Double(t.total)) * 100)
            return "\(ByteFormat.string(t.done)) / \(ByteFormat.string(t.total)) · \(pct)%"
        }
        return ByteFormat.string(t.done)
    }

    private var logSection: some View {
        QuietSection(title: "Request log", divider: false) {
            Button("Clear") { model.tftpLog.removeAll() }
                .buttonStyle(QuietBorderedStyle(height: 26, size: 12.5))
                .disabled(model.tftpLog.isEmpty)
        } content: {
            VStack(spacing: 0) {
                TFTPLogHeader()
                if model.tftpLog.isEmpty {
                    // Key off the selected server's own state, not TFTP's — on the
                    // SFTP/FTP tab this used to say "Turn the server on" while that
                    // server was already listening.
                    Text(selectedRunning
                        ? "Waiting for requests — run the copy command on the device."
                        : "Turn the server on, then run the copy command on the device.")
                        .font(Theme.detail)
                        .foregroundStyle(Theme.muted)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(model.tftpLog.prefix(30)) { entry in
                        TFTPLogRow(entry: entry)
                    }
                }
            }
        }
    }

    private func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: model.tftpRootPath)
        if panel.runModal() == .OK, let url = panel.url {
            model.setTFTPRoot(url.path)
        }
    }
}

/// Column widths for the request-log table.
private enum LogColumns {
    static let time: CGFloat = 64
    static let device: CGFloat = 128
    static let result: CGFloat = 96
}

private struct TFTPLogHeader: View {
    var body: some View {
        HStack(spacing: 8) {
            Text("Time").frame(width: LogColumns.time, alignment: .leading)
            Text("Device").frame(width: LogColumns.device, alignment: .leading)
            Text("Request").frame(maxWidth: .infinity, alignment: .leading)
            Text("Result").frame(width: LogColumns.result, alignment: .trailing)
        }
        .font(Theme.columnHeader)
        .foregroundStyle(Theme.faint)
        .padding(.bottom, 6)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        .accessibilityHidden(true)
    }
}

/// One request-log row: Time / Device / Request / Result.
struct TFTPLogRow: View {
    let entry: TFTPLogEntry

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        HStack(spacing: 8) {
            Text(Self.timeFormatter.string(from: entry.time))
                .font(Theme.detail)
                .monospacedDigit()
                .foregroundStyle(Theme.muted)
                .frame(width: LogColumns.time, alignment: .leading)
            Text(entry.peer)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: LogColumns.device, alignment: .leading)
            Text("\(entry.isWrite ? "write" : "read") \(entry.filename)")
                .font(Theme.detail)
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(entry.detail)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(resultColor)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: LogColumns.result, alignment: .trailing)
                .help(entry.detail)
        }
        .frame(minHeight: 34)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line.opacity(0.6)).frame(height: 1) }
        .textSelection(.enabled)
        .accessibilityElement(children: .combine)
    }

    private var resultColor: Color {
        if entry.failed { return Theme.attention }
        if entry.detail == "started" { return Theme.muted }
        return Theme.ok
    }
}
