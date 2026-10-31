import Combine
import Foundation

public enum HomeMotorExamStep: Equatable {
    case idle
    case task1PromptedVoice
    case task2PromptedHandwriting
    case task3PromptedTimedWalk
    case submitting
    case completed
}

public enum TaskMeasurementStatus: String { case measured, skipped, unavailable }

/// The three tasks' raw measurements, assembled as the exam proceeds.
public struct HomeMotorExamMeasurements {
    public var voiceMeanDbfs: Double = -24.0
    /// Std-dev in dB over the 5s sustained vowel only, excluding the spoken
    /// sentence so normal prosody does not inflate it.
    public var voiceStabilityDb: Double = 0.0
    /// Negative when letters shrink across the line (e.g. -35.0 for 35%).
    public var handwritingOpencvDecayPct: Double = 0.0
    public var handwritingSamDecayPct: Double?
    public var walkCadenceSpm: Double = 0.0
    public var walkMeanFI: Double = 0.0
    public var walkFogCount: Int = 0

    /// Which steps produced a real measurement. A step that was skipped or
    /// failed stays false, and its value is never shown as a result.
    public var voiceStatus: TaskMeasurementStatus = .unavailable
    public var handwritingStatus: TaskMeasurementStatus = .unavailable
    public var walkStatus: TaskMeasurementStatus = .unavailable
    public var measurementSource = "device"
    public var voiceMeasured: Bool {
        get { voiceStatus == .measured }
        set { voiceStatus = newValue ? .measured : .unavailable }
    }
    public var handwritingMeasured: Bool {
        get { handwritingStatus == .measured }
        set { handwritingStatus = newValue ? .measured : .unavailable }
    }
    public var walkMeasured: Bool {
        get { walkStatus == .measured }
        set { walkStatus = newValue ? .measured : .unavailable }
    }

    public func validated() -> HomeMotorExamMeasurements {
        var result = self
        if !voiceMeanDbfs.isFinite || !voiceStabilityDb.isFinite || voiceStabilityDb < 0 { result.voiceStatus = .unavailable }
        if !handwritingOpencvDecayPct.isFinite { result.handwritingStatus = .unavailable }
        if !walkCadenceSpm.isFinite || !walkMeanFI.isFinite || walkCadenceSpm < 0 || walkMeanFI < 0 || walkFogCount < 0 { result.walkStatus = .unavailable }
        if let refinement = result.handwritingSamDecayPct, !refinement.isFinite { result.handwritingSamDecayPct = nil }
        return result
    }

    public init() {}

    /// What was actually measured, for trends and the diary.
    public func record(at date: Date) -> TaskMetricsRecord {
        let valid = validated()
        return TaskMetricsRecord(
            date: date,
            voiceMeanDbfs: valid.voiceMeasured ? voiceMeanDbfs : nil,
            handwritingDecayPct: valid.handwritingMeasured ? handwritingOpencvDecayPct : nil,
            walkStepsPerMinute: valid.walkMeasured ? walkCadenceSpm : nil,
            walkFreezes: valid.walkMeasured ? walkFogCount : nil
        )
    }
}

/// What the backend returns from `POST /api/v1/exam/complete`.
public struct HomeMotorExamResult: Decodable {
    public let examUUID: String
    public let medicationStateLabel: String?
    public let voiceScore: Double?
    public let handwritingScore: Double?
    public let gaitScore: Double?
    public let compositeMotorScore: Double?
    public let clinicalSummary: String

    enum CodingKeys: String, CodingKey {
        case examUUID = "exam_uuid"
        case medicationStateLabel = "medication_state_label"
        case voiceScore = "voice_score"
        case handwritingScore = "handwriting_score"
        case gaitScore = "gait_score"
        case compositeMotorScore = "composite_motor_score"
        case clinicalSummary = "clinical_summary"
    }
}

/// Submits a completed exam and returns the scored result.
public protocol ExamSubmitting {
    func submit(examJSON: Data, bearerToken: String) async throws -> HomeMotorExamResult?
}

/// Posts to `POST /api/v1/exam/complete`.
///
/// Unlike telemetry events, an exam is interactive: the wearer is standing
/// there waiting to hear their score, so this returns the scored body rather
/// than going through the fire-and-forget offline queue. If the post fails the
/// exam is handed to `EventSyncManager`, which retries it in the background —
/// the wearer loses the spoken score but the neurologist still gets the data.
public struct URLSessionExamSubmitter: ExamSubmitting {
    public let baseURL: String
    public let timeoutSec: TimeInterval

    public init(baseURL: String, timeoutSec: TimeInterval = 8.0) {
        self.baseURL = baseURL
        self.timeoutSec = timeoutSec
    }

    public func submit(examJSON: Data, bearerToken: String) async throws -> HomeMotorExamResult? {
        guard let url = URL(string: "\(baseURL)/api/v1/exam/complete") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeoutSec
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        req.httpBody = examJSON
        let json = (try? JSONSerialization.jsonObject(with: examJSON)) as? [String: Any]
        req.setValue(String(json?["data_generation"] as? Int ?? 0), forHTTPHeaderField: "X-Cadence-Data-Generation")
        let data = try await URLSessionJSONTransport(timeoutSec: timeoutSec).send(req, bearerToken: bearerToken)
        return try JSONDecoder().decode(HomeMotorExamResult.self, from: data)
    }
}

/// Pipeline 6 (Demo-Critical P0): Guided 3-Step Home Motor Exam state machine.
///
/// Walks the wearer through voice, handwriting and a timed walk, then submits
/// the raw measurements to the backend. What the wearer sees and hears is
/// the measurements themselves and how they compare with the last check.
@MainActor
public final class HomeMotorExamManager: ObservableObject {
    @Published public private(set) var currentStep: HomeMotorExamStep = .idle
    @Published public private(set) var lastResult: HomeMotorExamResult?
    @Published public private(set) var lastResultSummary: String?
    @Published public private(set) var historyPersistenceWarning: String?
    /// The latest check's raw measurements and the one before, for trends.
    @Published public private(set) var lastRecord: TaskMetricsRecord?
    @Published public private(set) var previousRecord: TaskMetricsRecord?
    public var history: TaskMetricsHistory

    public var measurements = HomeMotorExamMeasurements()
    public private(set) var examSessionID = UUID()
    public var backendBaseURL: String = "http://localhost:8000" {
        didSet { submitter = URLSessionExamSubmitter(baseURL: backendBaseURL) }
    }
    public var deviceBearerToken: String = "cadence-dev-device-writer-token-2026"

    private var submitter: ExamSubmitting
    private let audio: AudioCueEngine
    private let sync: EventSyncManager
    public let voiceMonitor: VoiceMonitor

    /// Seconds each prompt is given before the demo advances itself.
    public var stepPauseSec: Double = 1.0

    public init(
        submitter: ExamSubmitting? = nil,
        audio: AudioCueEngine = .shared,
        sync: EventSyncManager = .shared,
        voiceMonitor: VoiceMonitor = .shared,
        history: TaskMetricsHistory? = nil
    ) {
        let isRunningInTest = NSClassFromString("XCTestCase") != nil
        self.history = history ?? (isRunningInTest
            ? TaskMetricsHistory(directory: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("motor-\(UUID().uuidString)"))
            : .default)
        self.submitter = submitter ?? URLSessionExamSubmitter(baseURL: "http://localhost:8000")
        self.audio = audio
        self.sync = sync
        self.voiceMonitor = voiceMonitor
    }

    public var isRunning: Bool {
        currentStep != .idle && currentStep != .completed
    }

    /// The prompt currently on screen, or nil when no exam is in progress.
    public var currentPrompt: String? {
        switch currentStep {
        case .idle: return nil
        case .task1PromptedVoice:
            return "Step 1 of 3 — Take a deep breath and say “Ahhh” steadily for 5 seconds, then read today's sentence."
        case .task2PromptedHandwriting:
            return "Step 2 of 3 — Write the test sentence on your pad, then look down at the line."
        case .task3PromptedTimedWalk:
            return "Step 3 of 3 — Stand up when ready and walk forward in a straight line for 10 seconds."
        case .submitting: return "Saving your motor check…"
        case .completed: return "Motor check complete."
        }
    }

    // MARK: - Step transitions

    public func startExam() {
        _ = voiceMonitor.stopVowelPhonationRecording()
        voiceMonitor.stopLiveMonitoring()
        examSessionID = UUID()
        measurements = HomeMotorExamMeasurements()
        lastRecord = nil
        previousRecord = nil
        currentStep = .task1PromptedVoice
        lastResult = nil
        lastResultSummary = nil
        historyPersistenceWarning = nil
        measurements.voiceMeasured = false
        measurements.handwritingMeasured = false
        measurements.walkMeasured = false
        voiceMonitor.startVowelPhonationRecording()
        audio.speakPrompt(
            "Step 1: Take a deep breath and say Ahhh steadily for 5 seconds, then read today's sentence.",
            priority: 2
        )
    }

    public func advanceToHandwriting() {
        currentStep = .task2PromptedHandwriting
        let (meanDbfs, stabilityDb) = voiceMonitor.stopVowelPhonationRecording()
        if voiceMonitor.lastVowelSampleCount >= 2 && meanDbfs.isFinite && stabilityDb.isFinite {
            measurements.voiceMeanDbfs = meanDbfs
            measurements.voiceStabilityDb = stabilityDb
            measurements.voiceMeasured = true
        }
        voiceMonitor.stopLiveMonitoring()
        audio.speakPrompt(
            "Step 2: Write the test sentence on your pad, then look down at the line.",
            priority: 2
        )
    }

    public func skipVoice() {
        _ = voiceMonitor.stopVowelPhonationRecording()
        voiceMonitor.stopLiveMonitoring()
        measurements.voiceStatus = .skipped
        currentStep = .task2PromptedHandwriting
    }

    public func advanceToTimedWalk() {
        currentStep = .task3PromptedTimedWalk
        audio.speakPrompt(
            "Step 3: Stand up when ready and walk forward in a straight line for 10 seconds.",
            priority: 2
        )
    }

    /// Submits the collected measurements and keeps the raw ones on the phone
    /// for trends. Nothing spoken or shown is a score.
    ///
    /// Returns the backend's result, or nil when it could not be reached — in
    /// that case the exam is queued for retry.
    @discardableResult
    public func completeExam(examUUID: String = UUID().uuidString) async -> HomeMotorExamResult? {
        guard currentStep != .submitting else { return nil }
        let session = examSessionID
        let token = deviceBearerToken; let base = backendBaseURL
        let dataGeneration = sync.currentDataGeneration
        let snapshot = measurements.validated()
        measurements = snapshot
        currentStep = .submitting

        var payload: [String: Any] = [
            "data_generation": dataGeneration,
            "exam_uuid": examUUID,
            "timestamp_utc": ISO8601DateFormatter().string(from: Date()),
            "voice_status": snapshot.voiceStatus.rawValue,
            "handwriting_status": snapshot.handwritingStatus.rawValue,
            "walk_status": snapshot.walkStatus.rawValue,
            "measurement_source": snapshot.measurementSource,
        ]
        if snapshot.voiceMeasured {
            payload["voice_mean_dbfs"] = snapshot.voiceMeanDbfs
            payload["voice_stability_db"] = snapshot.voiceStabilityDb
        }
        if snapshot.handwritingMeasured {
            payload["handwriting_opencv_decay_pct"] = snapshot.handwritingOpencvDecayPct
            if let samDecay = snapshot.handwritingSamDecayPct { payload["handwriting_sam_decay_pct"] = samDecay }
        }
        if snapshot.walkMeasured {
            payload["walk_cadence_spm"] = snapshot.walkCadenceSpm
            payload["walk_mean_fi"] = snapshot.walkMeanFI
            payload["walk_fog_count"] = snapshot.walkFogCount
        }

        guard let body = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            currentStep = .completed
            return nil
        }

        let record = snapshot.record(at: Date())
        previousRecord = history.latest()
        lastRecord = record
        do { try history.append(record) }
        catch { historyPersistenceWarning = "This phone's task history could not be saved. Keep the app open and try again." }

        let submission: HomeMotorExamResult?
        do { submission = try await submitter.submit(examJSON: body, bearerToken: token) }
        catch CadenceAPIError.dataGenerationChanged(let current) {
            guard examSessionID == session, deviceBearerToken == token, backendBaseURL == base else { return nil }
            sync.observeDataGeneration(current, bearerToken: token, baseURL: base)
            lastResultSummary = "Server data was erased. This check was not restored to the server; the local copy remains."
            currentStep = .completed
            return nil
        } catch { submission = nil }
        if let result = submission {
            guard examSessionID == session, deviceBearerToken == token, backendBaseURL == base else { return nil }
            lastResult = result
            lastResultSummary = TaskMetricsSummary.diaryDetail(record)
            currentStep = .completed
            audio.speakPrompt(historyPersistenceWarning == nil
                ? "Motor check done. Your results are in your diary."
                : "Your check was sent, but this phone's history could not be saved.", priority: 2)
            return result
        }

        guard examSessionID == session, deviceBearerToken == token, backendBaseURL == base else { return nil }
        // Offline: queue it so the care team still receives it later.
        if case let .failure(error) = sync.saveLocalImmediate(
            eventUUID: examUUID, endpoint: "/api/v1/exam/complete", payload: payload, dataGeneration: dataGeneration
        ) {
            lastResultSummary = error.message
            currentStep = .completed
            audio.speakPrompt("Your check could not be saved safely. Keep Cadence open and try again.", priority: 2)
            return nil
        }
        lastResultSummary = "Saved on this phone. Sharing will retry when connected."
        currentStep = .completed
        audio.speakPrompt(
            "Motor check done. It's saved on your phone. Sharing will retry when connected.",
            priority: 2
        )
        return nil
    }

    public func cancelExam() {
        examSessionID = UUID()
        currentStep = .idle
        audio.cancelNonEmergencySpeech()
        _ = voiceMonitor.stopVowelPhonationRecording()
        voiceMonitor.stopLiveMonitoring()
    }

    /// Runs all three prompts back to back for the demo, then submits.
    /// Returns a one-line summary for the status banner.
    @discardableResult
    public func runDemoExam(
        measurements seeded: HomeMotorExamMeasurements? = nil,
        examUUID: String = "exam-\(UUID().uuidString.prefix(8))"
    ) async -> String {
        startExam()
        let session = examSessionID
        await pause()
        guard examSessionID == session else { return "Demo canceled." }
        advanceToHandwriting()
        await pause()
        guard examSessionID == session else { return "Demo canceled." }
        advanceToTimedWalk()
        await pause()
        guard examSessionID == session else { return "Demo canceled." }

        // Only an explicitly supplied fixture supplies measurements.
        if var seeded {
            seeded.voiceMeasured = true
            seeded.handwritingMeasured = true
            seeded.walkMeasured = true
            seeded.measurementSource = "simulated"
            measurements = seeded
        }
        let result = await completeExam(examUUID: examUUID)
        let detail = lastRecord.map(TaskMetricsSummary.diaryDetail) ?? "Motor check done"
        if result != nil {
            return "Motor check saved — \(detail)"
        }
        return lastResultSummary ?? "The check could not be saved. Please try again."
    }

    private func pause() async {
        guard stepPauseSec > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(stepPauseSec * 1_000_000_000))
    }
}
