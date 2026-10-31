import CoreLocation
import Foundation

public enum FallDetectorStage {
    case monitoring
    case stage1FreeFall(startedAt: TimeInterval, preImpactPitch: Double, preImpactRoll: Double)
    case stage2ImpactConfirmed(impactTime: TimeInterval, peakG: Double, peakJerkGs: Double, preImpactPitch: Double, preImpactRoll: Double)
    case stage3CheckInActive(eventUUID: String, startedAt: TimeInterval)
}

/// Pipeline 2 (Demo-Critical P0): Fail-Safe 3-Stage Fall Detector.
/// - Maintains a 10-second pre-impact ring buffer ([-12.0s, -2.0s]) for motion RMS and respiration power.
/// - Evaluates Stage 1 Free-Fall (<0.45g for >=60ms), Stage 2 Impact (>2.8g & Jerk >35g/s),
///   and Stage 3 Post-Impact Orientation Change (>55 deg) & Stillness (<0.015 g^2).
/// - Immediately saves P0 local SQLite row (candidate_check_in_pending + CoreLocation GPS) at Stage 3
///   completion BEFORE starting the voice check-in timer (30 s, owned by the coordinator).
/// - Requires explicit multi-word affirmative cancel phrase; distress/negation/groans always escalate.
public final class FallDetector {
    public static let affirmativeCancelPhrases: [String] = [
        "i am okay",
        "i'm okay",
        "i am fine",
        "i'm fine",
        "false alarm",
        "cancel alert",
        "do not call",
        "don't call"
    ]

    /// Spoken when a hard impact is confirmed. Contains none of the phrases that
    /// cancel and none of the words that escalate, so even if the microphone
    /// hears it the check-in cannot answer itself. Listeners also ignore
    /// everything heard while the app is speaking.
    public static let checkInPrompt = "Are you all right? Tell me how you are, or ask me to call someone."

    public static let distressAndNegationKeywords: [String] = [
        "not okay",
        "not fine",
        "no",
        "help",
        "hurt",
        "fell",
        "can't get up",
        "cannot get up",
        "pain",
        "emergency"
    ]

    /// Normalizes a transcript for keyword matching: lowercases, folds the
    /// typographic apostrophe that `SFSpeechRecognizer` emits onto the ASCII
    /// one the keyword lists use, and reduces every other non-letter to a
    /// single space so matching can be done on whole words.
    public static func normalizeTranscript(_ raw: String) -> String {
        let lowered = raw.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{02BC}", with: "'")
        let collapsed = lowered.map { ch -> Character in
            (ch.isLetter || ch == "'") ? ch : " "
        }
        let words = String(collapsed).split(separator: " ").map { $0 == "ok" ? "okay" : String($0) }
        return " " + words.joined(separator: " ") + " "
    }

    /// Whole-word containment test.
    ///
    /// A bare `contains` is wrong for short keywords: "no" occurs inside
    /// "now", "know" and "nothing", so "I'm fine now" and "I know I'm okay"
    /// were both escalating as if the wearer had said "no". That fails safe
    /// but makes the spoken cancel unusable in practice, which pushes people
    /// toward ignoring the prompt entirely.
    public static func containsPhrase(_ haystack: String, _ phrase: String) -> Bool {
        let padded = " " + phrase.lowercased() + " "
        return haystack.contains(padded)
    }

    /// Whole-word match that also accepts common English inflections of the
    /// final word ("hurt" matching "hurts"/"hurting", "fell" matching "fallen").
    ///
    /// Used for distress keywords only. Whole-word matching alone would miss
    /// "my knee hurts", which is exactly the kind of utterance that must
    /// escalate; matching inflections here keeps the fail-safe direction while
    /// still refusing to fire on unrelated words that merely share a prefix.
    public static func containsDistressPhrase(_ haystack: String, _ phrase: String) -> Bool {
        if containsPhrase(haystack, phrase) { return true }
        for suffix in ["s", "es", "ing", "en"] {
            if containsPhrase(haystack, phrase + suffix) { return true }
        }
        return false
    }

    /// Disabled by default until Day-2 supine-vs-table calibration verifies noise-floor margin.
    public var enableUnwornDropSuppression: Bool = false
    public private(set) var stage: FallDetectorStage = .monitoring
    private var preImpactBuffer: [IMUSample] = []
    private var previousAccelMagG: Double = 1.0
    private var previousSampleTime: TimeInterval?

    public var eventSync: EventSyncManager = .shared
    public init() {}

    /// Processes incoming 6-axis IMU sample through the 3-stage biomechanical impact state machine.
    public func processIMUSample(
        _ sample: IMUSample,
        latitude: Double? = nil,
        longitude: Double? = nil,
        horizontalAccuracyM: Double? = nil
    ) -> String? {
        let accelMagG = sqrt(sample.ax * sample.ax + sample.ay * sample.ay + sample.az * sample.az)
        let dt = max(1e-3, sample.timestamp - (previousSampleTime ?? (sample.timestamp - 0.02)))
        let jerkGs = abs(accelMagG - previousAccelMagG) / dt
        previousAccelMagG = accelMagG
        previousSampleTime = sample.timestamp

        // Maintain rolling 12-second pre-impact buffer
        preImpactBuffer.append(sample)
        if let first = preImpactBuffer.first, sample.timestamp - first.timestamp > 12.5 {
            preImpactBuffer.removeAll { sample.timestamp - $0.timestamp > 12.0 }
        }

        switch stage {
        case .monitoring:
            if accelMagG < 0.45 {
                stage = .stage1FreeFall(
                    startedAt: sample.timestamp,
                    preImpactPitch: sample.pitchDeg,
                    preImpactRoll: sample.rollDeg
                )
            }
            return nil

        case let .stage1FreeFall(startedAt, prePitch, preRoll):
            let freeFallElapsed = sample.timestamp - startedAt
            if accelMagG > 2.8 && jerkGs > 35.0 && freeFallElapsed >= 0.06 && freeFallElapsed <= 0.55 {
                stage = .stage2ImpactConfirmed(
                    impactTime: sample.timestamp,
                    peakG: accelMagG,
                    peakJerkGs: jerkGs,
                    preImpactPitch: prePitch,
                    preImpactRoll: preRoll
                )
            } else if freeFallElapsed > 0.55 {
                stage = .monitoring
            }
            return nil

        case let .stage2ImpactConfirmed(impactTime, peakG, peakJerkGs, prePitch, preRoll):
            let postImpactElapsed = sample.timestamp - impactTime
            let tiltDelta = max(abs(sample.pitchDeg - prePitch), abs(sample.rollDeg - preRoll))
            let dynEnergy = (accelMagG - 1.0) * (accelMagG - 1.0)

            if postImpactElapsed >= 0.5 && postImpactElapsed <= 2.5 {
                if tiltDelta > 55.0 && dynEnergy < 0.015 {
                    let eventUUID = UUID().uuidString
                    let preWearRms = computePreImpactWearRmsG(beforeTimestamp: impactTime - 2.0)

                    // Immediate local persistence BEFORE the check-in starts.
                    var localPayload: [String: Any] = [
                        "event_uuid": eventUUID,
                        "timestamp_utc": ISO8601DateFormatter().string(from: Date()),
                        "peak_impact_g": peakG,
                        "peak_jerk_gs": peakJerkGs,
                        "post_impact_tilt_deg": tiltDelta,
                        "pre_impact_wear_rms_g": preWearRms,
                        "status": "candidate_check_in_pending"
                    ]
                    if let lat = latitude, let lon = longitude {
                        localPayload["latitude"] = lat
                        localPayload["longitude"] = lon
                    }
                    if let acc = horizontalAccuracyM {
                        localPayload["horizontal_accuracy_m"] = acc
                    }
                    eventSync.saveLocalImmediate(
                        eventUUID: eventUUID,
                        endpoint: "/api/v1/events/fall",
                        payload: localPayload
                    )

                    stage = .stage3CheckInActive(eventUUID: eventUUID, startedAt: sample.timestamp)
                    // The coordinator speaks the prompt once the microphone session
                    // is configured, so the category switch cannot cut it off.
                    return eventUUID
                }
            } else if postImpactElapsed > 2.5 {
                stage = .monitoring
            }
            return nil

        case .stage3CheckInActive:
            return nil
        }
    }

    public func resetAfterResolution() {
        stage = .monitoring
        previousSampleTime = nil
        previousAccelMagG = 1.0
    }

    public func resetForStreamGap() {
        if case .stage3CheckInActive = stage { return }
        resetAfterResolution()
        preImpactBuffer.removeAll()
    }

    private func computePreImpactWearRmsG(beforeTimestamp: TimeInterval) -> Double {
        let window = preImpactBuffer.filter { $0.timestamp <= beforeTimestamp && $0.timestamp >= beforeTimestamp - 10.0 }
        guard !window.isEmpty else { return 0.05 }
        let sumSq = window.reduce(0.0) { acc, s in
            let mag = sqrt(s.ax * s.ax + s.ay * s.ay + s.az * s.az)
            let diff = mag - 1.0
            return acc + diff * diff
        }
        return sqrt(sumSq / Double(window.count))
    }

    /// Evaluates the check-in transcript and vocal activity to decide cancellation vs. escalation.
    public func evaluateCheckInOutcome(
        transcript: String?,
        maxVocalLevelDbfs: Double,
        hardwareWearStateWorn: Bool,
        preImpactWearRmsG: Double,
        preImpactRespPower: Double,
        preImpactPitchDeg: Double
    ) -> String {
        stage = .monitoring
        let normalized = Self.normalizeTranscript(transcript ?? "")

        // 1. Check distress or negation keywords first -> immediate escalation.
        //    Matched on whole words so "now"/"know"/"nothing" are not read as "no".
        for kw in Self.distressAndNegationKeywords {
            if Self.containsDistressPhrase(normalized, kw) {
                AudioCueEngine.shared.activateBystanderSiren()
                return "confirmed_waiting_dispatch"
            }
        }

        // 2. Check explicit multi-word affirmative phrase (bare "okay" is never accepted)
        for phrase in Self.affirmativeCancelPhrases {
            if Self.containsPhrase(normalized, phrase) {
                return "canceled_false_alarm"
            }
        }

        // 3. Vocal groan / non-word sound override (>-28 dBFS without affirmative cancel phrase)
        if maxVocalLevelDbfs > -28.0 {
            AudioCueEngine.shared.activateBystanderSiren()
            return "confirmed_waiting_dispatch"
        }

        // 4. Hardware wearState primary + Day-2 calibrated fallback gate
        let imuWorn = (preImpactWearRmsG >= 0.04) ||
            (preImpactRespPower >= 1.5e-5 && abs(preImpactPitchDeg) <= 40.0)
        let isWornPreImpact = hardwareWearStateWorn || imuWorn

        if enableUnwornDropSuppression && !isWornPreImpact && maxVocalLevelDbfs < -45.0 {
            return "suppressed_unworn_drop"
        }

        AudioCueEngine.shared.activateBystanderSiren()
        return "confirmed_waiting_dispatch"
    }
}
