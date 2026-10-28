import SwiftUI

/// 24-Hour Objective Neurologist Summary & ON/OFF Diary Report (Pipeline 7).
/// Fetches the clinician report from `/api/v1/report/neurologist` including
/// 30-minute motor burden S(t_k) timeline, ON vs OFF exam deltas, and Llama 3.3 narrative.
public struct ClinicalReportView: View {
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
                VStack(spacing: 20) {
                    if isLoading {
                        loadingCard
                    } else if let report = report {
                        headerSummaryCard(report)
                        statsGrid(report.summary)
                        timelineCard(report.buckets)
                        narrativeCard(report.clinicalNarrative)
                        dashboardLinkCard
                    } else if let error = errorMessage {
                        errorCard(error)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 64)
            }
            .background(CadenceTheme.background.ignoresSafeArea())
            .navigationTitle("Clinical Report")
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
                }
            }
            .task {
                await fetchReport()
            }
        }
    }

    // MARK: - Loading

    private var loadingCard: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.4)
                .tint(CadenceTheme.accent)
            Text("Loading 24-Hour Clinical Summary…")
                .font(.headline)
            Text("Aggregating 48 half-hour motor intervals, Levodopa doses, and exam scores.")
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .card()
    }

    // MARK: - Header summary

    private func headerSummaryCard(_ report: NeurologistReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                IconBadge(systemName: "waveform.path.ecg", color: CadenceTheme.accent, size: 40)
                Spacer()
                StatusPill(text: "24-Hour Summary", color: CadenceTheme.calm, filled: true)
            }
            Text("Neurologist Objective Report")
                .font(.title2.weight(.bold))
            Text("Patient: \(report.patientID.replacingOccurrences(of: "_", with: " ").capitalized)")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .card()
    }

    // MARK: - Stats Grid

    private func statsGrid(_ summary: ReportSummary) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Medication State Share")
                .font(.headline)
                .foregroundColor(.secondary)

            HStack(spacing: 10) {
                statePillCard(title: "ON State", value: String(format: "%.0f%%", summary.onPct), color: CadenceTheme.calm)
                statePillCard(title: "Wearing OFF", value: String(format: "%.0f%%", summary.wearingOffPct), color: CadenceTheme.caution)
                statePillCard(title: "OFF State", value: String(format: "%.0f%%", summary.offPct), color: CadenceTheme.danger)
            }

            Divider().padding(.vertical, 4)

            HStack(spacing: 12) {
                metricRow(title: "Freezing of Gait", count: summary.fogCount, icon: "metronome.fill", color: CadenceTheme.accent)
                Divider()
                metricRow(title: "Falls Checked", count: summary.fallCount, icon: "shield.fill", color: CadenceTheme.danger)
            }
        }
        .card()
    }

    private func statePillCard(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundColor(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.12)))
    }

    private func metricRow(title: String, count: Int, icon: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(color)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(count)")
                    .font(.headline.monospacedDigit())
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Timeline Ribbon

    private func timelineCard(_ buckets: [DiaryBucket]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("24-Hour Motor Ribbon")
                .font(.headline)
                .foregroundColor(.secondary)
            Text("48 half-hour clinical intervals: Green = ON, Amber = Wearing OFF, Red = OFF, Gray = Pre-dose.")
                .font(.caption)
                .foregroundColor(.secondary)

            // Timeline segmented bar
            HStack(spacing: 2) {
                ForEach(buckets) { bucket in
                    Rectangle()
                        .fill(colorForState(bucket.clinicalState))
                        .frame(height: 28)
                        .cornerRadius(2)
                }
            }
            .frame(maxWidth: .infinity)

            HStack {
                Text("24h ago")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                Text("12h ago")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                Text("Now")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .card()
    }

    private func colorForState(_ state: String) -> Color {
        switch state.uppercased() {
        case "ON": return CadenceTheme.calm
        case "WEARING_OFF": return CadenceTheme.caution
        case "OFF": return CadenceTheme.danger
        default: return Color.secondary.opacity(0.3)
        }
    }

    // MARK: - Clinical Narrative (Llama 3.3 70B)

    private func narrativeCard(_ narrative: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "brain.head.profile")
                    .foregroundColor(CadenceTheme.accent)
                Text("Llama 3.3 Clinical Narrative")
                    .font(.headline)
                Spacer()
                StatusPill(text: "AI Neurologist Summary", color: CadenceTheme.accent)
            }

            Text(narrative)
                .font(.body)
                .foregroundColor(.primary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .card()
    }

    // MARK: - Dashboard Link

    private var dashboardLinkCard: some View {
        VStack(spacing: 12) {
            Text("Looking for the complete clinical audit?")
                .font(.subheadline)
                .foregroundColor(.secondary)

            if let url = URL(string: "\(app.settings.backendBaseURL)/dashboard") {
                Link(destination: url) {
                    HStack {
                        Label("Open Full Neurologist Dashboard", systemImage: "safari.fill")
                        Spacer()
                        Image(systemName: "arrow.up.right")
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: CadenceTheme.minimumTapHeight)
                    .background(CadenceTheme.accent)
                    .cornerRadius(CadenceTheme.controlRadius)
                }
            }
        }
        .card()
    }

    private func errorCard(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            StatusPill(text: "Could not load report", color: CadenceTheme.danger, filled: true)
            Text(error)
                .font(.body)
                .foregroundColor(.secondary)
            GuardedButton(size: .big, style: .tinted(CadenceTheme.accent), action: {
                Task { await fetchReport() }
            }) {
                Text("Retry")
            }
        }
        .card()
    }

    // MARK: - Logic

    private func fetchReport() async {
        isLoading = true
        errorMessage = nil
        do {
            let client = app.settings.api
            let res = try await client.fetchReport()
            await MainActor.run {
                self.report = res
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.errorMessage = "Could not fetch report from \(app.settings.backendBaseURL): \(error.localizedDescription)"
                self.isLoading = false
            }
        }
    }
}
