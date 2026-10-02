import SwiftUI

/// The Activity screen: every live transfer plus the session history, with a
/// today summary in the header.
struct TransfersView: View {
    @ObservedObject private var model = AppModel.shared

    private var liveTabs: [SessionTab] {
        model.tabs.filter { $0.sftp?.transfer != nil }
    }

    var body: some View {
        QuietPage(title: "Activity", subtitle: todaySummary) {
            VStack(alignment: .leading, spacing: 0) {
                if liveTabs.isEmpty && model.transferHistory.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No transfers yet")
                            .font(Theme.subtitle)
                            .foregroundStyle(Theme.ink)
                        Text("Uploads and downloads from every connection land here.")
                            .font(Theme.body)
                            .foregroundStyle(Theme.muted)
                    }
                    .padding(.top, 16)
                } else {
                    if !liveTabs.isEmpty {
                        GroupLabel(text: "In progress")
                            .padding(.bottom, 4)
                        ForEach(liveTabs) { tab in
                            LiveTransferRow(tab: tab)
                        }
                    }
                    if !model.transferHistory.isEmpty {
                        GroupLabel(text: "History")
                            .padding(.top, liveTabs.isEmpty ? 0 : 24)
                            .padding(.bottom, 4)
                        ForEach(model.transferHistory) { record in
                            HistoryTransferRow(record: record)
                        }
                    }
                }
            }
        }
    }

    private var todaySummary: String {
        let calendar = Calendar.current
        let today = model.transferHistory.filter { calendar.isDateInToday($0.finished) }
        guard !today.isEmpty else { return "Nothing transferred today" }
        let failed = today.filter(\.failed).count
        let suffix = failed == 0 ? "" : " · \(failed) failed"
        return "\(today.count) transfer\(today.count == 1 ? "" : "s") today\(suffix)"
    }
}
