import Foundation

/// What one ingested sample changed. Spectral fields are nil until a hop runs.
public struct LiveEdgeUpdate {
    public let freezeIndex: Double?
    public let fogActive: Bool?
    public let armingMode: String?
    public let fallEventUUID: String?
}

/// Feeds a sample stream into the gait and fall detectors.
///
/// Phone motion and the kinematic replayer both end here, so the hop timing,
/// the yaw integral, and the sit-to-stand cue are not reimplemented in the view.
public final class LiveEdgeEngine {
    public let fogDetector: FoGDetector
    public let fallDetector: FallDetector
    private var stream: SensorStreamManager
    private var yaw = YawTurnTracker()
    private var sitToStand = SitToStandMonitor()
    private var lastCueTimestamp: TimeInterval?

    public init(
        fogDetector: FoGDetector = FoGDetector(),
        fallDetector: FallDetector = FallDetector(),
        stream: SensorStreamManager = SensorStreamManager()
    ) {
        self.fogDetector = fogDetector
        self.fallDetector = fallDetector
        self.stream = stream
    }

    /// Drops buffered samples so a new scenario does not inherit the last one.
    /// The detectors themselves keep their state.
    public func beginSegment() {
        stream = SensorStreamManager()
        yaw = YawTurnTracker()
        sitToStand = SitToStandMonitor()
        lastCueTimestamp = nil
    }

    public func ingest(
        _ sample: IMUSample,
        latitude: Double? = nil,
        longitude: Double? = nil,
        horizontalAccuracyM: Double? = nil
    ) -> LiveEdgeUpdate {
        stream.appendSample(sample)
        yaw.add(timestamp: sample.timestamp, yawRateRadPerSec: sample.gy)

        let fallUUID = fallDetector.processIMUSample(
            sample,
            latitude: latitude,
            longitude: longitude,
            horizontalAccuracyM: horizontalAccuracyM
        )

        // The cue clock starts with the first sample, not when the FFT window
        // fills, so five seconds of sitting counts even though the spectrum
        // needs about 2.5 s of samples.
        let cueDue: Bool
        if let lastCueTimestamp {
            cueDue = sample.timestamp - lastCueTimestamp >= stream.hopDurationSec
        } else {
            self.lastCueTimestamp = sample.timestamp
            cueDue = false
        }
        guard cueDue else {
            return LiveEdgeUpdate(
                freezeIndex: nil, fogActive: nil, armingMode: nil, fallEventUUID: fallUUID
            )
        }
        self.lastCueTimestamp = sample.timestamp

        let windowReady = stream.bufferedDurationSec >= 2.4
        let window = windowReady ? stream.uniformResampledWindow() : []
        guard windowReady, window.count >= 16 else {
            let magnitude = sqrt(sample.ax * sample.ax + sample.ay * sample.ay + sample.az * sample.az)
            let quiet = abs(magnitude - 1.0) < 0.15
            _ = sitToStand.update(
                totalEnergy: quiet ? 0.0 : 0.1,
                ay: sample.ay,
                pitchDeg: sample.pitchDeg
            )
            return LiveEdgeUpdate(
                freezeIndex: nil, fogActive: nil, armingMode: nil, fallEventUUID: fallUUID
            )
        }

        let sampledHz = stream.estimatedSampleRateHz
        let metrics = fogDetector.computeSpectralMetrics(window: window, sampledHz: sampledHz)
        // A stand-up can be obvious in the current sample before it fills the
        // 2.5 s spectral window, so the sample is allowed to break stillness.
        let magnitude = sqrt(sample.ax * sample.ax + sample.ay * sample.ay + sample.az * sample.az)
        let sampleMoved = abs(magnitude - 1.0) > 0.15
        let stoodUp = sitToStand.update(
            totalEnergy: sampleMoved ? max(metrics.totalDynamicEnergy, 0.1) : metrics.totalDynamicEnergy,
            ay: sample.ay,
            pitchDeg: sample.pitchDeg
        )
        let active = fogDetector.evaluateHop(
            locomotorBandPower: metrics.locomotorBandPower,
            freezeBandPower: metrics.freezeBandPower,
            integratedYaw15sDeg: yaw.integratedDegrees(),
            pitchDeg: sample.pitchDeg,
            rollDeg: sample.rollDeg,
            sitToStandDetected: stoodUp,
            isUserSpeaking: VoiceMonitor.shared.isUserSpeaking,
            sampledHz: sampledHz
        )
        return LiveEdgeUpdate(
            freezeIndex: metrics.freezeIndex,
            fogActive: active,
            armingMode: fogDetector.armingMode.rawValue,
            fallEventUUID: fallUUID
        )
    }
}
