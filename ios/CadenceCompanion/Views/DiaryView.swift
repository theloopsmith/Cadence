import SwiftUI

/// A timeline of the day with icons and plain facts. No charts to read,
/// no interpretation.
struct DiaryView: View {
    @ObservedObject var app: CadenceAppModel
    @State private var day = Date()
    @State private var events: [DiaryEvent] = []
    @State private var facts: [String] = []
    @State private var showingReport = false

    private var isToday: Bool { Calendar.current.isDateInToday(day) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: CadenceTheme.tapGap) {
                    dayPicker
                    factsCard
                    reportCard
                    if events.isEmpty {
                        emptyCard
                    } else {
                        ForEach(events) { event in
                            eventRow(event)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 96)
            }
            .background(CadenceTheme.background.ignoresSafeArea())
            .navigationTitle("Diary")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingReport = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .accessibilityLabel("Share a summary")
                    }
                }
            }
            .sheet(isPresented: $showingReport) {
                ShareSummaryView(app: app)
            }
            .onAppear(perform: reload)
            .onChange(of: app.diaryVersion) { _ in reload() }
            .onChange(of: day) { _ in reload() }
        }
    }

    private var dayPicker: some View {
        HStack(spacing: CadenceTheme.tapGap) {
            GuardedButton(size: .big, style: .tinted(CadenceTheme.accent), action: {
                day = Calendar.current.date(byAdding: .day, value: -1, to: day) ?? day
            }) {
                Image(systemName: "chevron.left")
            }
            .frame(width: 96)
            .accessibilityLabel("Previous day")

            VStack(spacing: 2) {
                Text(isToday ? "Today" : day.formatted(.dateTime.weekday(.wide)))
                    .font(.title3.weight(.semibold))
                Text(day.formatted(.dateTime.month(.wide).day()))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)

            GuardedButton(size: .big, style: .tinted(CadenceTheme.accent), action: {
                day = Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day
            }) {
                Image(systemName: "chevron.right")
            }
            .frame(width: 96)
            .disabled(isToday)
            .opacity(isToday ? 0.4 : 1)
            .accessibilityLabel("Next day")
        }
    }

    private var factsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(facts, id: \.self) { fact in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 7))
                        .foregroundColor(CadenceTheme.accent)
                        .accessibilityHidden(true)
                    Text(fact)
                        .font(.title3)
                }
            }
            Text("Plain counts to share with your care team. Not a measure of how you are doing.")
                .font(.footnote)
                .foregroundColor(.secondary)
                .padding(.top, 4)
        }
        .card()
    }

    private var reportCard: some View {
        Button {
            showingReport = true
        } label: {
            HStack(spacing: 12) {
                IconBadge(systemName: "square.and.arrow.up", color: CadenceTheme.accent, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Share a summary")
                        .font(.headline)
                        .foregroundColor(.primary)
                    Text("A PDF of your diary to send, print, or save")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundColor(.secondary)
            }
            .card()
        }
        .buttonStyle(.plain)
    }

    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(isToday ? "Nothing logged yet today" : "Nothing was logged this day")
                .font(.headline)
            Text("Beats, doses, and check-ins appear here as they happen.")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .card()
    }

    private func eventRow(_ event: DiaryEvent) -> some View {
        HStack(alignment: .top, spacing: 14) {
            IconBadge(systemName: event.kind.systemImage, color: color(for: event.kind))
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(event.kind.word)
                        .font(.headline)
                    Spacer()
                    Text(event.at.formatted(date: .omitted, time: .shortened))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
                if !event.factualDetail.isEmpty {
                    Text(event.factualDetail)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .card(padding: 16)
        .accessibilityElement(children: .combine)
    }

    private func color(for kind: DiaryEventKind) -> Color {
        switch kind {
        case .cue: return CadenceTheme.accent
        case .doseTaken, .mealLogged: return CadenceTheme.calm
        case .checkInAnswered: return CadenceTheme.calm
        case .helpSent: return CadenceTheme.danger
        case .alertAccepted: return CadenceTheme.accent
        case .caregiverAcknowledged: return CadenceTheme.calm
        case .protectionOn: return CadenceTheme.calm
        case .protectionOff: return .secondary
        case .environmentCheck, .motorCheck: return CadenceTheme.accent
        }
    }

    private func reload() {
        events = (try? app.diary.events(on: day)) ?? []
        facts = (try? app.diary.plainFacts(for: day)) ?? []
    }
}
