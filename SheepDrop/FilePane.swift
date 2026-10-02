import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct FileEntry: Identifiable, Hashable, Sendable {
    var id: String { name }
    let name: String
    let isDirectory: Bool
    let size: Int64
    let modified: Date?
    var permissions: String?
}

/// Local-filesystem pane model. The remote (SFTP) pane presents the same
/// FileEntry rows from the worker's listing, so FileListView serves both.
@MainActor
final class LocalPaneModel: ObservableObject {
    @Published var directoryURL: URL
    @Published var entries: [FileEntry] = []
    @Published var selection: String?

    init(directoryURL: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.directoryURL = directoryURL
        reload()
    }

    /// Bumped per reload so a slow enumeration that finishes after the user
    /// has already navigated elsewhere can't overwrite the newer listing.
    private var reloadGeneration = 0

    func reload() {
        // Enumerate + stat off the main thread — a huge folder (Downloads,
        // node_modules) used to beach-ball the UI on every reload/navigation.
        reloadGeneration += 1
        let generation = reloadGeneration
        let directory = directoryURL
        Task { @MainActor in
            let listed = await Task.detached(priority: .userInitiated) {
                Self.list(directory)
            }.value
            guard generation == self.reloadGeneration else { return }
            self.entries = listed
        }
    }

    nonisolated private static func list(_ directory: URL) -> [FileEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles])) ?? []
        return urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return FileEntry(
                name: url.lastPathComponent,
                isDirectory: values?.isDirectory ?? false,
                size: Int64(values?.fileSize ?? 0),
                modified: values?.contentModificationDate
            )
        }
        .sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func enter(_ entry: FileEntry) {
        guard entry.isDirectory else { return }
        directoryURL.appendPathComponent(entry.name)
        selection = nil
        reload()
    }

    /// At `/` this is a no-op — `deleteLastPathComponent()` on "/" appends
    /// "/..", so pressing Up at the root used to grow `/../../..` forever.
    var canGoUp: Bool { directoryURL.standardizedFileURL.path != "/" }

    func goUp() {
        let current = directoryURL.standardizedFileURL
        guard current.path != "/" else { return }
        directoryURL = current.deletingLastPathComponent().standardizedFileURL
        selection = nil
        reload()
    }

    /// Jump to a typed path (address bar). Absolute, `~`, or relative to the
    /// current folder; `..` resolves. Only changes if the folder exists.
    func open(_ rawPath: String) {
        var p = rawPath.trimmingCharacters(in: .whitespaces)
        let home = FileManager.default.homeDirectoryForCurrentUser
        if p.isEmpty || p == "~" {
            p = home.path
        } else if p == "~/" || p.hasPrefix("~/") {
            p = home.appendingPathComponent(String(p.dropFirst(2))).path
        } else if !p.hasPrefix("/") {
            p = directoryURL.appendingPathComponent(p).path
        }
        let url = URL(fileURLWithPath: p).standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              isDir.boolValue else { return }
        directoryURL = url
        selection = nil
        reload()
    }

    /// Native "choose a folder" dialog for the Mac side.
    func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = directoryURL
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            directoryURL = url
            selection = nil
            reload()
        }
    }

    var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = directoryURL.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

/// Column widths shared by the header and the rows so they line up.
enum FileColumns {
    static let size: CGFloat = 84
    static let perms: CGFloat = 84
    static let modified: CGFloat = 110
    static let icon: CGFloat = 22
    static let rowHeight: CGFloat = 34
}

struct FileColumnHeader: View {
    var showPerms = false

    var body: some View {
        HStack(spacing: 8) {
            Text("Name")
                .padding(.leading, FileColumns.icon)
            Spacer()
            Text("Size").frame(width: FileColumns.size, alignment: .trailing)
            if showPerms {
                Text("Perms").frame(width: FileColumns.perms, alignment: .trailing)
            }
            Text("Modified").frame(width: FileColumns.modified, alignment: .trailing)
        }
        .font(Theme.columnHeader)
        .foregroundStyle(Theme.faint)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.line).frame(height: 1)
        }
        .accessibilityHidden(true)
    }
}

struct FileListView: View {
    let entries: [FileEntry]
    @Binding var selection: String?
    var showPerms = false
    let onOpen: (FileEntry) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(entries) { entry in
                    FileRow(entry: entry, isSelected: selection == entry.name, showPerms: showPerms)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { onOpen(entry) }
                        .simultaneousGesture(TapGesture().onEnded { selection = entry.name })
                }
            }
            .padding(.vertical, 4)
        }
    }
}

/// One file row: 34 pt ("Comfortable"), 14 pt name, 13 pt size/date in the
/// secondary grey; the selection is a rounded fill.
struct FileRow: View {
    let entry: FileEntry
    let isSelected: Bool
    var showPerms = false

    var body: some View {
        HStack(spacing: 0) {
            // Functional glyphs: they tell file from folder.
            Image(systemName: entry.isDirectory ? "folder" : "doc")
                .font(.system(size: 14))
                .foregroundStyle(entry.isDirectory ? Theme.folder : Theme.faint)
                .frame(width: FileColumns.icon, alignment: .leading)
            Text(entry.name)
                .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                Text(entry.isDirectory ? "—" : ByteFormat.string(entry.size))
                    .frame(width: FileColumns.size, alignment: .trailing)
                if showPerms {
                    Text(entry.permissions ?? "")
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: FileColumns.perms, alignment: .trailing)
                }
                Text(DateFormat.string(entry.modified))
                    .frame(width: FileColumns.modified, alignment: .trailing)
            }
            .font(Theme.detail)
            .foregroundStyle(Theme.muted)
            .monospacedDigit()
            .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: FileColumns.rowHeight)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.selection)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Formatters are expensive to build; a file list re-renders these per row on
/// every scroll/selection. Cache one. ByteFormat stays nonisolated because
/// the TFTP server logs sizes off the main actor; ByteCountFormatter's
/// `string(fromByteCount:)` is a pure read and safe to share.
nonisolated enum ByteFormat {
    nonisolated(unsafe) private static let formatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    static func string(_ bytes: Int64) -> String {
        formatter.string(fromByteCount: bytes)
    }
}

@MainActor
enum DateFormat {
    private static let time = make("HH:mm")
    private static let thisYear = make("MMM d, HH:mm")
    private static let older = make("MMM d, yyyy")

    private static func make(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = format
        return formatter
    }

    static func string(_ date: Date?) -> String {
        guard let date else { return "--" }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return time.string(from: date)
        } else if calendar.isDate(date, equalTo: Date(), toGranularity: .year) {
            return thisYear.string(from: date)
        }
        return older.string(from: date)
    }
}
