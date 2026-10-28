import SwiftUI

/// Pick a time range, see what will be included, and share it as a PDF
/// through the iOS Share sheet. Built on the phone; nothing goes to a server.
struct ShareSummaryView: View {
    @ObservedObject var app: CadenceAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var range: SummaryRange = .lastWeek
    @State private var report: SummaryReport?
    @State private var fileURL: URL?
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: CadenceTheme.tapGap) {
                    rangeCard
                    if let report {
                        previewCard(report)
                    }
                    shareCard
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(CadenceTheme.background.ignoresSafeArea())
            .navigationTitle("Share a summary")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear(perform: rebuild)
            .onChange(of: range) { _ in rebuild() }
        }
    }

    private var rangeCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("How far back?")
                .font(.title3.weight(.semibold))
            ForEach(SummaryRange.allCases) { option in
                GuardedButton(
                    size: .big,
                    style: option == range ? .filled(CadenceTheme.accent) : .tinted(CadenceTheme.accent),
                    action: { range = option }
                ) {
                    HStack {
                        Text(option.buttonTitle)
                        Spacer()
                        if option == range {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                .accessibilityAddTraits(option == range ? .isSelected : [])
            }
        }
        .card()
    }

    private func previewCard(_ report: SummaryReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(report.title).font(.headline)
            Text(report.rangeText).font(.subheadline).foregroundColor(.secondary)
            if report.isEmpty {
                Text(SummaryReport.nothingLogged).font(.body)
            } else {
                ForEach(report.counts.filter { $0.value > 0 }, id: \.label) { count in
                    HStack {
                        Text(count.label)
                        Spacer()
                        Text("\(count.value)").monospacedDigit().fontWeight(.semibold)
                    }
                    .font(.body)
                }
                if !report.motorChecks.isEmpty {
                    Text("Includes \(report.motorChecks.count) motor check\(report.motorChecks.count == 1 ? "" : "s") with measurements.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
        }
        .card()
    }

    @ViewBuilder
    private var shareCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            InlineNotice(
                text: "Once shared, the summary is in the hands of whoever receives it. Share it with people you trust, like your care team.",
                color: CadenceTheme.accent,
                systemName: "hand.raised.fill"
            )
            if let problem {
                InlineNotice(text: problem)
            }
            if let fileURL {
                ShareLink(item: fileURL) {
                    Label("Share PDF", systemImage: "square.and.arrow.up")
                        .font(.title2.weight(.bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, minHeight: CadenceTheme.giantTapHeight)
                        .background(
                            RoundedRectangle(cornerRadius: CadenceTheme.cardRadius, style: .continuous)
                                .fill(CadenceTheme.calm)
                        )
                }
                .accessibilityHint("Opens the share sheet to send, print, or save the summary")
            }
        }
        .card()
    }

    private func rebuild() {
        let built = SummaryReportBuilder(diary: app.diary, metrics: app.exam.history)
            .build(range: range, endingAt: Date(), name: app.settings.summaryName)
        report = built
        do {
            fileURL = try SummaryPDFRenderer().writeTemporaryFile(built)
            problem = nil
        } catch {
            fileURL = nil
            problem = "The summary couldn't be prepared. Please try again."
        }
    }
}
