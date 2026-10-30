import Combine
import Foundation

/// Everything a tester needs to drive each feature without a real freeze, a
/// real fall, or waiting for a dose time. Lives behind the Developer switch.
@MainActor
public final class DeveloperToolsModel: ObservableObject {
    @Published public private(set) var backendStatus = "Not checked"
    @Published public private(set) var pendingEvents: [PendingEvent] = []
    @Published public private(set) var isReplaying = false
    @Published public private(set) var replayProgress = 0.0
    @Published public private(set) var replayName: String?
    @Published public private(set) var lastMessage: String?
    @Published public private(set) var lastEnvironmentCheck: RealityCheckResult?
    @Published public private(set) var lastMeal: MealProteinResult?
    @Published public private(set) var isBusy = false

    public var replaySampleIntervalNs: UInt64 = 20_000_000

    public let app: CadenceAppModel
    private var replayTask: Task<Void, Never>?

    public init(app: CadenceAppModel) {
        self.app = app
    }

    // MARK: - Backend

    public func checkBackend() async {
        do {
            let health = try await app.settings.api.health()
            backendStatus = "Connected · version \(health.version)"
        } catch {
            backendStatus = "Not reachable at \(app.settings.backendBaseURL)"
        }
    }

    public func refreshQueue() {
        pendingEvents = app.settings.sync.dueEvents(now: .distantFuture)
    }

    public func drainQueue() async {
        isBusy = true
        let result = await app.settings.sync.drainPendingEvents()
        isBusy = false
        refreshQueue()
        lastMessage = "Sent \(result.delivered), still waiting \(result.failed)."
    }

    // MARK: - Walking

    public func replay(_ scenario: IMUScenario) {
        guard !isReplaying else { return }
        app.walking.stopFreezeDemo()
        app.motion.stopSource()
        app.motion.beginSegment()
        isReplaying = true
        replayProgress = 0
        replayName = scenario.rawValue
        let samples = IMUScenarioReplayer.generateSamples(scenario: scenario, sampleRateHz: 50)
        let interval = replaySampleIntervalNs
        replayTask = Task { [weak self] in
            for (index, sample) in samples.enumerated() {
                guard let self, !Task.isCancelled else { return }
                self.app.motion.ingest(sample, latitude: 37.7749, longitude: -122.4194, horizontalAccuracyM: 5)
                if index % 10 == 0 { self.replayProgress = Double(index) / Double(samples.count) }
                if interval > 0 { try? await Task.sleep(nanoseconds: interval) }
            }
            guard let self else { return }
            self.isReplaying = false
            self.replayProgress = 1
            self.lastMessage = "Replay finished: \(scenario.rawValue)"
            AudioCueEngine.shared.stopRASMetronome()
        }
    }

    public func stopReplay() {
        replayTask?.cancel()
        replayTask = nil
        isReplaying = false
        AudioCueEngine.shared.stopRASMetronome()
    }

    // MARK: - Fall check-in

    public func openSimulatedCheckIn() {
        app.fallAlert.beginCheckIn(eventUUID: "dev-\(UUID().uuidString.prefix(8))")
    }

    /// Feeds a phrase through the same rules the microphone would.
    public func simulateSpeech(_ transcript: String) {
        guard app.fallAlert.isAlertVisible else { return }
        app.fallAlert.resolveFromSpeech(
            transcript: transcript,
            maxVocalLevelDbfs: -20.0,
            hardwareWearStateWorn: app.glasses.isWorn ?? true,
            preImpactWearRmsG: 0.08,
            preImpactRespPower: 2.0e-5,
            preImpactPitchDeg: 8.0
        )
    }

    public func simulateSilence() {
        guard app.fallAlert.isAlertVisible else { return }
        app.fallAlert.resolveFromSpeech(
            transcript: nil,
            maxVocalLevelDbfs: -60.0,
            hardwareWearStateWorn: app.glasses.isWorn ?? true,
            preImpactWearRmsG: 0.08,
            preImpactRespPower: 2.0e-5,
            preImpactPitchDeg: 8.0
        )
    }

    public func standDownAlert() {
        if app.fallAlert.isAlertVisible { app.fallAlert.cancelByUser() }
    }

    // MARK: - Medication

    /// Adds a dose time a few minutes ago so the Taken button is on screen.
    public func makeDoseDueNow() {
        let cal = app.settings.schedule.calendar
        let now = Date()
        let hour = cal.component(.hour, from: now)
        let minute = max(0, cal.component(.minute, from: now) - 5)
        var times = app.settings.schedule.doseTimes
        let time = DoseTime(hour: hour, minute: minute)
        if !times.contains(time) { times.append(time) }
        app.settings.schedule.doseTimes = times.sorted()
        lastMessage = "Dose time \(hour):\(String(format: "%02d", minute)) added."
    }

    public func clearTodaysDoses() {
        let events = (try? app.diary.events(on: Date())) ?? []
        for event in events where event.kind == .doseTaken {
            try? app.diary.remove(id: event.id)
        }
        app.doses.schedule = app.settings.schedule
        app.diaryChanged()
    }

    public func setForcedSimpleMode(_ on: Bool?) {
        app.forcedSimpleMode = on
    }

    // MARK: - Camera checks (phone or glasses)

    public func runEnvironmentCheck(jpeg: Data, question: String) async {
        guard !isBusy, !app.settings.restartRequired else { return }
        isBusy = true
        defer { isBusy = false }
        let client = app.settings.api
        do {
            let result = try await client.realityCheck(question: question, jpeg: jpeg)
            guard !Task.isCancelled, !app.settings.restartRequired, app.settings.deviceToken == client.bearerToken,
                  app.settings.api.baseURL == client.baseURL else { return }
            lastEnvironmentCheck = result
            AudioCueEngine.shared.speakPrompt(result.spokenResponse, priority: 2)
            app.recordDiary(.environmentCheck, detail: result.spokenResponse)
            lastMessage = nil
        } catch {
            lastMessage = "Couldn't check the room: \(describe(error))"
        }
    }

    public func runMealCheck(jpeg: Data) async {
        isBusy = true
        defer { isBusy = false }
        do {
            let result = try await app.settings.api.logMeal(jpeg: jpeg)
            lastMeal = result
            AudioCueEngine.shared.speakPrompt(result.spokenResponse, priority: 2)
            app.recordDiary(.mealLogged, detail: "Meal time logged")
            lastMessage = nil
        } catch {
            lastMessage = "Couldn't check the meal: \(describe(error))"
        }
    }

    /// A still from the glasses camera, when connected.
    public func captureFromGlasses(_ completion: @escaping (Data?) -> Void) {
        guard !isBusy else { return completion(nil) }
        isBusy = true
        app.glasses.capturePhoto { [weak self] result in
            guard let self else { return }
            self.isBusy = false
            guard !self.app.settings.restartRequired else { return completion(nil) }
            switch result {
            case let .success(data): completion(data)
            case let .failure(error):
                self.lastMessage = error.errorDescription
                completion(nil)
            }
        }
    }

    // MARK: - Diary

    public func seedSampleDay() {
        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: Date())
        func todayAt(hour: Int, minute: Int) -> Date {
            cal.date(bySettingHour: hour, minute: minute, second: 0, of: startOfDay) ?? startOfDay
        }
        app.recordDiary(.protectionOn, detail: "", at: todayAt(hour: 8, minute: 0))
        app.recordDiary(.doseTaken, detail: app.settings.schedule.medicationName, at: todayAt(hour: 8, minute: 30))
        app.recordDiary(.cue, detail: "A steady beat helped you step again", at: todayAt(hour: 10, minute: 0))
        app.recordDiary(.cue, detail: "A steady beat helped you step again", at: todayAt(hour: 12, minute: 0))
        app.recordDiary(.environmentCheck, detail: "A coat was identified in the sample photo; the whole scene was not verified.", at: todayAt(hour: 13, minute: 0))
        app.recordDiary(.mealLogged, detail: "Meal time logged", at: todayAt(hour: 13, minute: 30))
        app.recordDiary(.motorCheck, detail: "Letters 22% smaller across the line · 96 steps a minute", at: todayAt(hour: 14, minute: 0))
        app.recordDiary(.checkInAnswered, detail: "You said you were okay", at: todayAt(hour: 15, minute: 0))
        app.recordDiary(.helpSent, detail: "Sample alert requested; caregiver receipt is unverified", at: todayAt(hour: 16, minute: 0))
        app.recordDiary(.protectionOff, detail: "", at: todayAt(hour: 17, minute: 0))
        lastMessage = "Sample day written to the diary."
    }

    public func clearToday() {
        let events = (try? app.diary.events(on: Date())) ?? []
        for event in events { try? app.diary.remove(id: event.id) }
        app.diaryChanged()
        lastMessage = "Today's diary cleared."
    }

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "the server could not be reached."
    }
}
