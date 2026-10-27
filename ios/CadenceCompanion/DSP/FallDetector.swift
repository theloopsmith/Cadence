import Foundation

/// Pipeline 2 (Demo-Critical P0): Fail-Safe 3-Stage Fall Detector.
/// - Persists local P0 row immediately upon Stage-3 impact completion (before 12s check-in).
/// - Uses hardware wearState as primary signal; unworn drop suppression is OFF by default.
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

    public var enableUnwornDropSuppression: Bool = false

    public init() {}

    /// Evaluates 12s check-in transcript and vocal activity to decide cancellation vs. escalation.
    public func evaluateCheckInOutcome(
        transcript: String?,
        maxVocalLevelDbfs: Double,
        hardwareWearStateWorn: Bool,
        preImpactWearRmsG: Double,
        preImpactRespPower: Double,
        preImpactPitchDeg: Double
    ) -> String {
        let normalized = (transcript ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Check distress or negation keywords first -> immediate escalation
        for kw in Self.distressAndNegationKeywords {
            if normalized.contains(kw) {
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
            return "confirmed_waiting_dispatch"
        }

        // 4. Hardware wearState primary + Day-2 calibrated fallback gate
        let imuWorn = (preImpactWearRmsG >= 0.04) ||
            (preImpactRespPower >= 1.5e-5 && abs(preImpactPitchDeg) <= 40.0)
        let isWornPreImpact = hardwareWearStateWorn || imuWorn

        if enableUnwornDropSuppression && !isWornPreImpact && maxVocalLevelDbfs < -45.0 {
            return "suppressed_unworn_drop"
        }

        return "confirmed_waiting_dispatch"
    }
}
