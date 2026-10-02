import AppKit
import SwiftUI

/// The "Quiet" look, shared with LabDC (owner, 27 Sep 2026): simple, refined,
/// monochrome. Hierarchy comes from type size, weight and whitespace; state
/// is written as words (in a small pill beside titles); the only colour is a
/// muted red for what went wrong, a muted green for what went right, and the
/// tiny per-protocol identity dots. Every page takes its values from here.
///
/// 2026-10-02 readability pass ("UI Clean ดูไม่รก"): text got bigger and
/// darker (secondary #605F59, faint #77766F), the chrome got smaller (one
/// 64 pt header bar instead of a 40 pt top + 28 pt light title, 20–24 pt
/// margins instead of 48).
enum Theme {
    // MARK: Colour (light / dark)

    /// Page background: warm ivory / near-black.
    static let background = dynamic(light: 0xFBFAF7, dark: 0x141413)
    /// The sidebar: one step darker (light) or lighter (dark) than the page.
    static let sidebar = dynamic(light: 0xF3F1EC, dark: 0x1B1B1A)
    static let ink = dynamic(light: 0x141414, dark: 0xF1F0EC)
    /// Secondary text: sizes, dates, subtitles, labels (6.1 : 1 on ivory;
    /// 7.2 : 1 on the dark page).
    static let muted = dynamic(light: 0x605F59, dark: 0xA3A29C)
    /// Tertiary text: column headers, group labels, host subtitles
    /// (≥ 4.4 : 1 on ivory; 5.5 : 1 on the dark page).
    static let faint = dynamic(light: 0x77766F, dark: 0x8E8D87)
    /// Hairline rules between sections and rows.
    static let line = dynamic(light: 0xE4E1DA, dark: 0x2B2A28)
    /// Field / button borders and the inactive switch track.
    static let control = dynamic(light: 0xD4D1C9, dark: 0x45443F)
    /// The one warning colour: what went wrong, destructive actions.
    static let attention = dynamic(light: 0x9B3B2E, dark: 0xE08A7C)
    /// Success: a completed transfer, "Connected", "Listening".
    static let ok = dynamic(light: 0x3E7350, dark: 0x7CB88E)
    /// The pale fill behind a green status pill.
    static let okFill = dynamic(light: 0xECF2EA, dark: 0x1D2A21)
    /// The pale fill behind a red status pill.
    static let attentionFill = dynamic(light: 0xF6EAE6, dark: 0x2E1E1B)
    /// Inset fill for path fields, code and copyable values.
    static let inset = dynamic(light: 0xF1EFEA, dark: 0x1F1F1E)
    /// The segmented-control track and the sidebar's info box.
    static let track = dynamic(light: 0xE8E5DE, dark: 0x262624)
    /// The selected row of a table (rounded fill, no edge).
    static let selection = dynamic(light: 0xEDEAE3, dark: 0x252523)
    /// The selected row in the sidebar (one step darker than the sidebar).
    static let sidebarSelection = dynamic(light: 0xE6E2DA, dark: 0x2A2A28)
    /// Progress-bar track.
    static let barTrack = dynamic(light: 0xECEAE4, dark: 0x2B2A28)
    /// Folder glyphs in the file lists (warm clay).
    static let folder = dynamic(light: 0x9C6444, dark: 0xB8836A)

    /// The four protocols keep a tiny identity dot — the one place colour is
    /// allowed beyond red/green state. Muted hues, tuned to sit in the ivory /
    /// near-black world; used ONLY for the dot, nowhere else.
    static func protoColor(_ proto: TransferProtocolKind) -> Color {
        switch proto {
        case .sftp: dynamic(light: 0x5E7D5A, dark: 0x7E9E79)   // moss
        case .scp:  dynamic(light: 0x77688F, dark: 0x9688AC)   // heather
        case .ftp:  dynamic(light: 0x9C6444, dark: 0xB8836A)   // clay
        case .tftp: dynamic(light: 0x4E7D82, dark: 0x6F9DA2)   // teal grey
        }
    }

    // MARK: Type
    //
    // One scale for the app: 18 semibold titles · 14 semibold sections ·
    // 14 names · 13 body/detail · 12 semibold column headers · 11 caps group
    // labels · 12.5 mono paths.

    /// Page / host title at the top of a page or sheet.
    static let pageTitle = Font.system(size: 18, weight: .semibold)
    /// A heading inside a pane (empty / not-connected states).
    static let subtitle = Font.system(size: 16, weight: .semibold)
    /// Section headings ("Settings", "Request log").
    static let heading = Font.system(size: 14, weight: .semibold)
    /// Row titles, pane titles.
    static let emphasis = Font.system(size: 13, weight: .semibold)
    /// File and host names.
    static let name = Font.system(size: 14)
    static let body = Font.system(size: 13)
    /// Sizes, dates, subtitles (paired with `muted`).
    static let detail = Font.system(size: 13)
    /// Sidebar subtitles, small notes.
    static let small = Font.system(size: 12)
    /// Table column headers.
    static let columnHeader = Font.system(size: 12, weight: .semibold)
    static let caption = Font.system(size: 11)
    /// Group labels: use through `GroupLabel` (uppercase, tracked).
    static let groupLabel = Font.system(size: 11, weight: .semibold)
    static let mono = Font.system(size: 12.5, design: .monospaced)

    // MARK: Space

    static let pageInsets = EdgeInsets(top: 24, leading: 24, bottom: 24, trailing: 24)
    static let maxContentWidth: CGFloat = 1400
    static let rowPadding: CGFloat = 10
    /// The page header bar (session / server / activity).
    static let headerHeight: CGFloat = 64

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

// MARK: - Page structure

/// The standard page: a 64 pt header bar (18 pt title, optional one-line
/// subtitle, actions on the right, hairline under it), then the content with
/// 24 pt margins. No card, no icon chrome.
struct QuietPage<Actions: View, Content: View>: View {
    let title: String
    var subtitle: String?
    var scrolls = true
    @ViewBuilder var actions: Actions
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            QuietHeaderBar {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Theme.pageTitle)
                        .foregroundStyle(Theme.ink)
                        .accessibilityAddTraits(.isHeader)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.muted)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 16)
                HStack(spacing: 12) { actions }
            }
            if scrolls {
                ScrollView { paddedContent }
            } else {
                paddedContent.frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .background(Theme.background)
    }

    private var paddedContent: some View {
        content
            .padding(Theme.pageInsets)
            .frame(maxWidth: Theme.maxContentWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension QuietPage where Actions == EmptyView {
    init(title: String, subtitle: String? = nil, scrolls: Bool = true, @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, scrolls: scrolls, actions: { EmptyView() }, content: content)
    }
}

/// The one header bar every main-column page uses: 64 pt, 20–24 pt side
/// margins, a hairline under it.
struct QuietHeaderBar<Content: View>: View {
    var horizontalPadding: CGFloat = 24
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 14) { content }
            .padding(.horizontal, horizontalPadding)
            .frame(height: Theme.headerHeight)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}

/// A segmented row of text tabs ("SFTP  SCP  TFTP  FTP").
struct QuietTabs<Value: Hashable>: View {
    let items: [(Value, String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                SegmentButton(title: item.1, selected: item.0 == selection, height: 28) {
                    selection = item.0
                }
            }
        }
        .padding(2)
        .background(Theme.track, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

/// One segment of a segmented control (sidebar Client | Server, sheet tabs):
/// the selected one is a raised page-coloured pill.
struct SegmentButton: View {
    let title: String
    let selected: Bool
    var height: CGFloat = 30
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Theme.ink : Theme.muted)
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Theme.background)
                            .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A section of a page: a 14 pt title (optional trailing accessory) and its
/// content — no card; a hairline under it separates it from the next one.
struct QuietSection<Trailing: View, Content: View>: View {
    let title: String
    var divider = true
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text(title)
                    .font(Theme.heading)
                    .foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                trailing
            }
            content
        }
        .padding(.bottom, divider ? 22 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            if divider { Rectangle().fill(Theme.line).frame(height: 1) }
        }
        .accessibilityElement(children: .contain)
    }
}

extension QuietSection where Trailing == EmptyView {
    init(title: String, divider: Bool = true, @ViewBuilder content: () -> Content) {
        self.init(title: title, divider: divider, trailing: { EmptyView() }, content: content)
    }
}

/// One row with a hairline above it (the first row of a list omits the line with `first: true`).
struct QuietRow<Content: View>: View {
    var first = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            if !first { Rectangle().fill(Theme.line).frame(height: 1) }
            content
                .padding(.vertical, Theme.rowPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A label above a value, for sheets and detail panes.
struct QuietFieldLabel<Value: View>: View {
    let label: String
    @ViewBuilder var value: Value

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(Theme.groupLabel)
                .tracking(0.66)
                .textCase(.uppercase)
                .foregroundStyle(Theme.muted)
            value.font(Theme.name).foregroundStyle(Theme.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// An uppercase group label ("RECENT", "LISTENERS").
struct GroupLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.groupLabel)
            .tracking(0.66)
            .textCase(.uppercase)
            .foregroundStyle(Theme.faint)
            .lineLimit(1)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Buttons

/// A quiet text action: a word with a thin underline (used sparingly now —
/// most actions are bordered buttons or icon buttons).
struct QuietLinkStyle: ButtonStyle {
    var role: ButtonRole?
    var size: CGFloat = 13
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let color = role == .destructive ? Theme.attention : Theme.ink
        configuration.label
            .font(.system(size: size))
            .foregroundStyle(color)
            .underline(true, color: color.opacity(0.3))
            .opacity(isEnabled ? (configuration.isPressed ? 0.55 : 1) : 0.35)
            .contentShape(Rectangle())
    }
}

/// The single strong action of a screen (Connect, Add Device…, Copy): ink
/// fill, page-coloured text.
struct QuietPrimaryStyle: ButtonStyle {
    var height: CGFloat = 32
    var fullWidth = false
    var size: CGFloat = 13
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(Theme.background)
            .padding(.horizontal, 16)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(height: height)
            .background(Theme.ink, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.3)
            .contentShape(Rectangle())
    }
}

/// A secondary action: hairline border, no fill (Disconnect, Change…, Clear).
struct QuietBorderedStyle: ButtonStyle {
    var role: ButtonRole?
    var height: CGFloat = 32
    var size: CGFloat = 13
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let radius: CGFloat = height < 30 ? 6 : 8
        configuration.label
            .font(.system(size: size))
            .foregroundStyle(role == .destructive ? Theme.attention : Theme.ink)
            .padding(.horizontal, height < 30 ? 10 : 14)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(configuration.isPressed ? Theme.inset : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.control, lineWidth: 1)
            )
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Rectangle())
    }
}

/// A borderless square icon button (back chevron, close ×, ↑, refresh).
struct QuietIconStyle: ButtonStyle {
    var size: CGFloat = 28
    var tint: Color = Theme.ink

    func makeBody(configuration: Configuration) -> some View {
        QuietIconBody(configuration: configuration, size: size, tint: tint)
    }
}

private struct QuietIconBody: View {
    let configuration: ButtonStyleConfiguration
    let size: CGFloat
    let tint: Color
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        configuration.label
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size > 30 ? 8 : 6, style: .continuous)
                    .fill(configuration.isPressed ? Theme.track
                          : (hovering && isEnabled ? Theme.inset : Color.clear))
            )
            .opacity(isEnabled ? 1 : 0.3)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

extension ButtonStyle where Self == QuietLinkStyle {
    static var quietLink: QuietLinkStyle { QuietLinkStyle() }
    static var quietDestructive: QuietLinkStyle { QuietLinkStyle(role: .destructive) }
}

extension ButtonStyle where Self == QuietPrimaryStyle {
    static var quietPrimary: QuietPrimaryStyle { QuietPrimaryStyle() }
}

extension ButtonStyle where Self == QuietBorderedStyle {
    static var quietBordered: QuietBorderedStyle { QuietBorderedStyle() }
    /// The compact 28 pt variant (Change… / Show / Clear inside sections).
    static var quietBorderedSmall: QuietBorderedStyle { QuietBorderedStyle(height: 28, size: 12.5) }
}

/// An SF Symbol inside a QuietIconStyle button, with a tooltip and an
/// accessibility label (icon buttons never go unlabeled).
struct IconButton: View {
    let systemName: String
    let label: String
    var size: CGFloat = 28
    var symbolSize: CGFloat = 14
    var tint: Color = Theme.ink
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: symbolSize, weight: .medium))
        }
        .buttonStyle(QuietIconStyle(size: size, tint: tint))
        .help(label)
        .accessibilityLabel(label)
    }
}

/// The monochrome switch (ink when on), label on the left.
struct QuietToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 10) {
                configuration.label
                Spacer(minLength: 0)
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule().fill(configuration.isOn ? Theme.ink : Theme.control).frame(width: 38, height: 22)
                    Circle().fill(Color.white).frame(width: 18, height: 18).padding(2)
                        .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
                }
                .animation(.easeOut(duration: 0.15), value: configuration.isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

extension ToggleStyle where Self == QuietToggleStyle {
    static var quiet: QuietToggleStyle { QuietToggleStyle() }
}

/// A text field with only a line under it (sheet fields).
struct QuietFieldStyle: TextFieldStyle {
    var size: CGFloat = 14

    func _body(configuration: TextField<Self._Label>) -> some View {
        VStack(spacing: 5) {
            configuration
                .textFieldStyle(.plain)
                .font(.system(size: size))
                .foregroundStyle(Theme.ink)
            Rectangle().fill(Theme.control).frame(height: 1)
        }
    }
}

extension TextFieldStyle where Self == QuietFieldStyle {
    static var quiet: QuietFieldStyle { QuietFieldStyle() }
}

/// A quiet filled box field (server settings): 30 pt, hairline border.
struct QuietBoxFieldStyle: TextFieldStyle {
    var size: CGFloat = 13.5

    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(.system(size: size))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Theme.inset.opacity(0.6), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Theme.control.opacity(0.8), lineWidth: 1))
    }
}

extension TextFieldStyle where Self == QuietBoxFieldStyle {
    static var quietBox: QuietBoxFieldStyle { QuietBoxFieldStyle() }
}

// MARK: - State as words

/// The status pill beside a title: a dot and a word ("Connected",
/// "Listening · port 22", "Off"). Green when good, red when failed, neutral
/// otherwise.
struct StatusPill: View {
    enum Kind { case ok, neutral, busy, attention }
    let text: String
    var kind: Kind = .neutral

    var body: some View {
        HStack(spacing: 6) {
            if kind == .busy {
                ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 9, height: 9)
            } else {
                Circle().fill(fg).frame(width: 7, height: 7)
            }
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(fg)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(bg, in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    private var fg: Color {
        switch kind {
        case .ok: Theme.ok
        case .attention: Theme.attention
        case .neutral, .busy: Theme.muted
        }
    }

    private var bg: Color {
        switch kind {
        case .ok: Theme.okFill
        case .attention: Theme.attentionFill
        case .neutral, .busy: Theme.inset
        }
    }
}

/// A thin rounded progress bar (4 pt by default). `fraction == nil` draws an
/// indeterminate sliver.
struct QuietProgressBar: View {
    let fraction: Double?
    var height: CGFloat = 4
    var tint: Color = Theme.ink

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.barTrack)
                if let fraction {
                    Capsule().fill(tint)
                        .frame(width: max(height, geo.size.width * min(max(fraction, 0), 1)))
                } else {
                    TimelineView(.animation) { context in
                        let period = 1.4
                        let t = context.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: period) / period
                        Capsule().fill(tint)
                            .frame(width: geo.size.width * 0.25)
                            .offset(x: geo.size.width * (t * 1.25 - 0.25))
                    }
                    .clipShape(Capsule())
                }
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue(fraction.map { "\(Int($0 * 100)) percent" } ?? "In progress")
    }
}

/// "Connected" / "Off" / "Failed: …": text only; the attention colour when something is wrong.
struct StateText: View {
    let text: String
    var attention = false
    var dimmed = false

    var body: some View {
        Text(text)
            .font(Theme.detail)
            .foregroundStyle(attention ? Theme.attention : (dimmed ? Theme.faint : Theme.muted))
    }
}

/// A short note under a section.
struct QuietNote: View {
    let text: String
    var attention = false

    init(_ text: String, attention: Bool = false) {
        self.text = text
        self.attention = attention
    }

    var body: some View {
        Text(text)
            .font(Theme.detail)
            .foregroundStyle(attention ? Theme.attention : Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A Copy button that says "Copied" for a moment (LabDC's CopyButton).
/// `prominent` = the solid ink button beside the reach address.
struct CopyButton: View {
    let value: String
    var label = "Copy"
    var prominent = false
    @State private var copied = false

    var body: some View {
        if prominent {
            button.buttonStyle(QuietPrimaryStyle(height: 40))
        } else {
            button.buttonStyle(.quietBorderedSmall)
        }
    }

    private var button: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Text(copied ? "Copied" : label)
                .frame(minWidth: 44)
        }
        .accessibilityLabel(copied ? "Copied" : "\(label) \(value)")
    }
}
