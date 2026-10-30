import SwiftUI

/// The last 24 hours, counted: doses, beats played, falls, check-ins, and a
/// half-hour timeline coloured by what happened. A summary to share with a
/// care team, not an assessment.
public struct DaySummaryView: View {
    @ObservedObject var app: CadenceAppModel
    @Environment(\.dismiss) private var dismiss

    @State private var isLoading = true
    @State private var report: NeurologistReport?
    @State private var errorMessage: String?

    public init(app: CadenceAppModel) {
        self.app = app
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: CadenceTheme.tapGap) {
                    if isLoading {
                        loadingCard
                    } else if let report {
                        metadataCard(report.metadata)
                        summaryCard(report.clinicalNarrative)
                        countsCard(report.summary)
                        timelineCard(report.buckets)
                        shareCard
                    } else if let errorMessage {
                        errorCard(errorMessage)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 64)
            }
            .background(CadenceTheme.background.ignoresSafeArea())
            .navigationTitle("Last 24 hours")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await fetchReport() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh")
                }
            }
            .task { await fetchReport() }
        }
    }

    private var loadingCard: some View {
        VStack(spacing: 16) {
            ProgressView().scaleEffect(1.4).tint(CadenceTheme.accent)
            Text("Gathering the last 24 hours…").font(.headline)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .card()
    }

    @ViewBuilder
    private func metadataCard(_ metadata: ReportMetadata?) -> some View {
        if let metadata {
            VStack(alignment: .leading, spacing: 8) {
                Text("Report interval (UTC)").font(.headline)
                Text("\(metadata.windowStartUTC) to \(metadata.windowEndUTC)").font(.footnote)
                Text("Generated: \(metadata.generatedAtUTC)").font(.footnote)
                Text(metadata.latestEventUTC.map { "Latest logged event: \($0)" } ?? "No events logged in this interval.").font(.footnote)
                Text(metadata.coverageNote).font(.footnote).foregroundColor(.secondary)
            }.card()
        } else {
            InlineNotice(text: "This server did not provide report freshness or observation coverage.")
        }
    }

    private func summaryCard(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("In short")
                .font(.headline)
                .foregroundColor(.secondary)
            Text(text)
                .font(.title3)
                .fixedSize(horizontal: false, vertical: true)
            Text("Counts of what Cadence logged. Not a measure of how you are doing.")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .card()
    }

    private func countsCard(_ summary: ReportSummary) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("What happened")
                .font(.headline)
                .foregroundColor(.secondary)
            HStack(spacing: 12) {
                MetricTile(value: "\(summary.doseCount ?? 0)", label: "Doses logged", color: CadenceTheme.calm)
                MetricTile(value: "\(summary.fogCount)", label: "Walking pauses logged", color: CadenceTheme.accent)
            }
            HStack(spacing: 12) {
                MetricTile(value: "\(summary.fallCount)", label: "Fall alerts recorded", color: CadenceTheme.danger)
                MetricTile(value: "\(summary.fallCandidateResolvedCount)", label: "Check-ins answered okay", color: CadenceTheme.calm)
            }
            HStack(spacing: 12) {
                MetricTile(value: summary.caregiverProviderAcceptedCount.map(String.init) ?? "—", label: "Provider accepted", color: CadenceTheme.accent)
                MetricTile(value: summary.caregiverAcknowledgedCount.map(String.init) ?? "—", label: "Caregiver acknowledged", color: CadenceTheme.calm)
            }
            Text("Provider acceptance does not confirm receipt by a caregiver.").font(.footnote).foregroundColor(.secondary)
        }
        .card()
    }

    private func timelineCard(_ buckets: [DiaryBucket]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Through the day")
                .font(.headline)
                .foregroundColor(.secondary)

            HStack(spacing: 2) {
                ForEach(buckets) { bucket in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color(for: bucket.eventLevel))
                        .frame(height: 28)
                        .accessibilityLabel(accessibilityText(for: bucket))
                }
            }
            .frame(maxWidth: .infinity)

            HStack {
                Text(buckets.first?.labelHHMM ?? "").font(.caption2).foregroundColor(.secondary)
                Spacer()
                Text("Report end").font(.caption2).foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                legendRow(color(for: .unknown), "No observations; monitoring coverage unknown")
                legendRow(color(for: .none), "Other events logged")
                legendRow(color(for: .onePause), "One walking pause")
                legendRow(color(for: .more), "A fall, or several pauses")
            }
            .padding(.top, 4)
        }
        .card()
    }

    private func legendRow(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 18, height: 12)
                .accessibilityHidden(true)
            Text(text).font(.footnote)
        }
    }

    private func color(for level: DiaryBucket.EventLevel) -> Color {
        switch level {
        case .unknown: return Color.secondary.opacity(0.25)
        case .none: return CadenceTheme.accent.opacity(0.35)
        case .onePause: return CadenceTheme.caution
        case .more: return CadenceTheme.danger
        }
    }

    private func accessibilityText(for bucket: DiaryBucket) -> String {
        let pauses = bucket.fogCount ?? 0
        var parts: [String] = []
        if pauses > 0 { parts.append("\(pauses) walking \(pauses == 1 ? "pause" : "pauses")") }
        if bucket.fallOccurred == true { parts.append("a fall") }
        return "\(bucket.labelHHMM) UTC: " + (bucket.eventLevel == .unknown ? "no observations; monitoring coverage unknown" : (parts.isEmpty ? "other events logged" : parts.joined(separator: ", ")))
    }

    private var shareCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("The full summary, with times and details, can be opened in a browser by your care team.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let url = URL(string: "\(app.settings.backendBaseURL)/dashboard") {
                Link(destination: url) {
                    Label("Open the full summary", systemImage: "safari.fill")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, minHeight: CadenceTheme.bigTapHeight)
                        .background(
                            RoundedRectangle(cornerRadius: CadenceTheme.cardRadius, style: .continuous)
                                .fill(CadenceTheme.accent)
                        )
                }
            }
        }
        .card()
    }

    private func errorCard(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            InlineNotice(text: error)
            GuardedButton(size: .big, style: .tinted(CadenceTheme.accent), action: {
                Task { await fetchReport() }
            }) {
                Text("Try again")
            }
        }
        .card()
    }

    private func fetchReport() async {
        isLoading = true
        errorMessage = nil
        do {
            let result = try await app.settings.api.fetchReport()
            report = result
            isLoading = false
        } catch {
            errorMessage = "Couldn't reach Cadence's server just now. You can view this phone’s local diary separately."
            isLoading = false
        }
    }
}
