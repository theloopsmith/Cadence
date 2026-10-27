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

    public init() {}
}

/// What the backend returns from `POST /api/v1/exam/complete`.
public struct HomeMotorExamResult: Decodable {
    public let examUUID: String
    public let medicationStateLabel: String
    public let voiceScore: Double
    public let handwritingScore: Double
    public let gaitScore: Double
    public let compositeMotorScore: Double
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
    func submit(examJSON: Data, bearerToken: String) async -> HomeMotorExamResult?
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

    public func submit(examJSON: Data, bearerToken: String) async -> HomeMotorExamResult? {
        guard let url = URL(string: "\(baseURL)/api/v1/exam/complete") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeoutSec
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        req.httpBody = examJSON
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else { return nil }
            return try JSONDecoder().decode(HomeMotorExamResult.self, from: data)
        } catch {
            return nil
        }
    }
}

/// Pipeline 6 (Demo-Critical P0): Guided 3-Step Home Motor Exam state machine.
///
/// Walks the wearer through voice, handwriting and a timed walk, then submits
/// the measurements to the backend, which owns the scoring. The scores are
/// deliberately not computed on device: the diary classifier and the ON/OFF
/// comparison must agree with them exactly, so there is one implementation of
/// the formulas and it lives in `app/services/motor_exam.py`.
@MainActor
public final class HomeMotorExamManager: ObservableObject {
    @Published public private(set) var currentStep: HomeMotorExamStep = .idle
    @Published public private(set) var lastResult: HomeMotorExamResult?
    @Published public private(set) var lastResultSummary: String?

    public var measurements = HomeMotorExamMeasurements()
    public var backendBaseURL: String = "http://localhost:8000" {
        didSet { submitter = URLSessionExamSubmitter(baseURL: backendBaseURL) }
    }
    public var deviceBearerToken: String = "cadence-dev-device-writer-token-2026"

    private var submitter: ExamSubmitting
    private let audio: AudioCueEngine
    private let sync: EventSyncManager

    /// Seconds each prompt is given before the demo advances itself.
    public var stepPauseSec: Double = 1.0

    public init(
        submitter: ExamSubmitting? = nil,
        audio: AudioCueEngine = .shared,
        sync: EventSyncManager = .shared
    ) {
        self.submitter = submitter ?? URLSessionExamSubmitter(baseURL: "http://localhost:8000")
        self.audio = audio
        self.sync = sync
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
        case .submitting: return "Scoring your motor check…"
        case .completed: return "Motor check complete."
        }
    }

    // MARK: - Step transitions

    public func startExam() {
        currentStep = .task1PromptedVoice
        lastResult = nil
        lastResultSummary = nil
        audio.speakPrompt(
            "Step 1: Take a deep breath and say Ahhh steadily for 5 seconds, then read today's sentence.",
            priority: 2
        )
    }

    public func advanceToHandwriting() {
        currentStep = .task2PromptedHandwriting
        audio.speakPrompt(
            "Step 2: Write the test sentence on your pad, then look down at the line.",
            priority: 2
        )
    }

    public func advanceToTimedWalk() {
        currentStep = .task3PromptedTimedWalk
        audio.speakPrompt(
            "Step 3: Stand up when ready and walk forward in a straight line for 10 seconds.",
            priority: 2
        )
    }

    /// Submits the collected measurements and speaks the composite score.
    ///
    /// Returns the scored result, or nil when the backend could not be reached
    /// — in that case the exam is queued for retry and the wearer is told the
    /// score will appear in their report rather than being given a number the
    /// device invented.
    @discardableResult
    public func completeExam(examUUID: String = UUID().uuidString) async -> HomeMotorExamResult? {
        currentStep = .submitting

        var payload: [String: Any] = [
            "exam_uuid": examUUID,
            "timestamp_utc": ISO8601DateFormatter().string(from: Date()),
            "voice_mean_dbfs": measurements.voiceMeanDbfs,
            "voice_stability_db": measurements.voiceStabilityDb,
            "handwriting_opencv_decay_pct": measurements.handwritingOpencvDecayPct,
            "walk_cadence_spm": measurements.walkCadenceSpm,
            "walk_mean_fi": measurements.walkMeanFI,
            "walk_fog_count": measurements.walkFogCount,
        ]
        // The SAM refinement is a visual overlay the backend treats as
        // optional. Only include it when there is a value: writing
        // `someOptional as Any` into the dictionary would serialize a JSON
        // null instead of omitting the key.
        if let samDecay = measurements.handwritingSamDecayPct {
            payload["handwriting_sam_decay_pct"] = samDecay
        }

        guard let body = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            currentStep = .completed
            return nil
        }

        if let result = await submitter.submit(examJSON: body, bearerToken: deviceBearerToken) {
            lastResult = result
            lastResultSummary = String(
                format: "%@ • Composite %.1f/100 (voice %.1f, writing %.1f, gait %.1f)",
                result.medicationStateLabel,
                result.compositeMotorScore,
                result.voiceScore,
                result.handwritingScore,
                result.gaitScore
            )
            currentStep = .completed
            audio.speakPrompt(
                String(
                    format: "Motor check complete. Your composite motor score is %.0f out of 100.",
                    result.compositeMotorScore
                ),
                priority: 2
            )
            return result
        }

        // Offline: queue it so the neurologist still receives the exam, and say
        // so plainly instead of reporting a score that was never computed.
        sync.saveLocalImmediate(
            eventUUID: examUUID,
            endpoint: "/api/v1/exam/complete",
            payload: payload
        )
        lastResultSummary = "Saved offline — your score will appear in your report once you reconnect."
        currentStep = .completed
        audio.speakPrompt(
            "Motor check recorded. I'll send it to your doctor when you're back online.",
            priority: 2
        )
        return nil
    }

    /// Runs all three prompts back to back for the demo, then submits.
    /// Returns a one-line summary for the status banner.
    @discardableResult
    public func runDemoExam(
        measurements seeded: HomeMotorExamMeasurements? = nil,
        examUUID: String = "exam-\(UUID().uuidString.prefix(8))"
    ) async -> String {
        if let seeded { measurements = seeded }

        startExam()
        await pause()
        advanceToHandwriting()
        await pause()
        advanceToTimedWalk()
        await pause()

        let result = await completeExam(examUUID: examUUID)
        if let result {
            return "Exam complete — \(result.medicationStateLabel), composite "
                + String(format: "%.1f/100", result.compositeMotorScore)
        }
        return "Exam saved offline — backend unreachable, queued for retry."
    }

    private func pause() async {
        guard stepPauseSec > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(stepPauseSec * 1_000_000_000))
    }
}
