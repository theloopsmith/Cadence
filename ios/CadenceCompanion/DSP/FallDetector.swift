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
///   completion BEFORE starting the 12-second voice check-in timer.
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

    public static let distressAndNegationKeywords: [String] = [
        "not okay",
        "not fine",
        "no",
        "help",
        "hurt",
        "fell",
        "can't get up",
        "pain",
        "emergency"
    ]

    /// Disabled by default until Day-2 supine-vs-table calibration verifies noise-floor margin.
    public var enableUnwornDropSuppression: Bool = false
    public private(set) var stage: FallDetectorStage = .monitoring
    private var preImpactBuffer: [IMUSample] = []
    private var previousAccelMagG: Double = 1.0
    private var previousSampleTime: TimeInterval?

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

                    // Immediate P0 Local Persistence BEFORE 12s check-in starts!
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
                    EventSyncManager.shared.saveLocalImmediate(
                        eventUUID: eventUUID,
                        endpoint: "/api/v1/events/fall",
                        payload: localPayload
                    )

                    stage = .stage3CheckInActive(eventUUID: eventUUID, startedAt: sample.timestamp)
                    AudioCueEngine.shared.speakPrompt(
                        "Hard impact detected. Say I am okay to cancel the caregiver alert.",
                        priority: 0
                    )
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

    /// Evaluates 12s check-in transcript and vocal activity to decide cancellation vs. escalation.
    public func evaluateCheckInOutcome(
        transcript: String?,
        maxVocalLevelDbfs: Double,
        hardwareWearStateWorn: Bool,
        preImpactWearRmsG: Double,
        preImpactRespPower: Double,
        preImpactPitchDeg: Double
    ) -> String {
        stage = .monitoring
        let normalized = (transcript ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Check distress or negation keywords first -> immediate escalation
        for kw in Self.distressAndNegationKeywords {
            if normalized.contains(kw) {
                AudioCueEngine.shared.activateBystanderSiren()
                return "confirmed_waiting_dispatch"
            }
        }

        // 2. Check explicit multi-word affirmative phrase (bare "okay" is never accepted)
        for phrase in Self.affirmativeCancelPhrases {
            if normalized.contains(phrase) {
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
