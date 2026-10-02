import SwiftUI

/// ⌘T sheet: protocol, address, credentials, optional name, and where to
/// save it — an existing group, a new group, or nowhere. Passwords are
/// collected on connect (Keychain), not here. Quiet form: underline fields,
/// word tabs for the protocol, one ink button.
struct QuickConnectSheet: View {
    @ObservedObject private var model = AppModel.shared
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var address = ""
    @State private var username = "admin"
    @State private var portText = ""
    @State private var proto: TransferProtocolKind = .sftp
    /// Sentinel raw values for the save picker.
    @State private var saveTarget = "none"
    @State private var newGroupName = ""

    private static let noneTag = "none"
    private static let newGroupTag = "__new__"

    init() {
        if let pending = AppModel.shared.pendingGroupID {
            _saveTarget = State(initialValue: pending.uuidString)
            AppModel.shared.pendingGroupID = nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Add Device")
                .font(Theme.pageTitle)
                .accessibilityAddTraits(.isHeader)
                .foregroundStyle(Theme.ink)

            QuietTabs(items: TransferProtocolKind.allCases.map { ($0, $0.label) },
                      selection: $proto)

            VStack(alignment: .leading, spacing: 14) {
                QuietFieldLabel(label: "Host or IP address") {
                    TextField("10.0.0.1", text: $address)
                        .textFieldStyle(.quiet)
                }
                HStack(alignment: .top, spacing: 20) {
                    QuietFieldLabel(label: "Username") {
                        TextField("admin", text: $username)
                            .textFieldStyle(.quiet)
                            .disabled(proto == .tftp)
                            .opacity(proto == .tftp ? 0.4 : 1)
                    }
                    QuietFieldLabel(label: "Port") {
                        TextField("\(proto.defaultPort)", text: $portText)
                            .textFieldStyle(.quiet)
                            .frame(width: 90)
                    }
                    Spacer()
                }
                QuietFieldLabel(label: "Name (optional)") {
                    TextField("BBL Core SW", text: $name)
                        .textFieldStyle(.quiet)
                }
                HStack(alignment: .top, spacing: 20) {
                    QuietFieldLabel(label: "Save to") {
                        Picker("", selection: $saveTarget) {
                            Text("Don't save").tag(Self.noneTag)
                            ForEach(model.groups) { group in
                                Text(group.name).tag(group.id.uuidString)
                            }
                            Divider()
                            Text("New group…").tag(Self.newGroupTag)
                        }
                        .labelsHidden()
                        .frame(width: 200)
                    }
                    if saveTarget == Self.newGroupTag {
                        QuietFieldLabel(label: "Group name") {
                            TextField("Aruba Lab", text: $newGroupName)
                                .textFieldStyle(.quiet)
                        }
                    }
                    Spacer()
                }
            }

            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.quietBordered)
                    .keyboardShortcut(.cancelAction)
                Button("Connect") { connect() }
                    .buttonStyle(.quietPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.top, 6)
        }
        .padding(24)
        .frame(width: 440)
        .background(Theme.background)
    }

    private func connect() {
        // Clamp to the valid TCP/UDP range — an out-of-range port used to trap
        // in UInt16() deep inside the FTP worker.
        let typedPort = Int(portText).flatMap { (1...65535).contains($0) ? $0 : nil }
        let host = HostEntry(
            name: name.trimmingCharacters(in: .whitespaces),
            address: address.trimmingCharacters(in: .whitespaces),
            port: typedPort ?? proto.defaultPort,
            username: proto == .tftp ? "" : username.trimmingCharacters(in: .whitespaces),
            proto: proto
        )

        switch saveTarget {
        case Self.noneTag:
            break
        case Self.newGroupTag:
            let groupName = newGroupName.trimmingCharacters(in: .whitespaces)
            if !groupName.isEmpty {
                let id = model.addGroup(named: groupName)
                model.addHost(host, toGroup: id)
            }
        default:
            if let id = UUID(uuidString: saveTarget) {
                model.addHost(host, toGroup: id)
            }
        }

        model.mainPane = .connection
        // Reuse an already-open tab to the same host instead of spawning a
        // second live connection (matches the sidebar's connect behaviour).
        if let existing = model.tabs.first(where: {
            $0.host.address == host.address && $0.host.port == host.port
                && $0.host.username == host.username && $0.host.proto == host.proto
        }) {
            model.selectedTabID = existing.id
        } else {
            model.openTab(for: host)
        }
        dismiss()
    }
}
