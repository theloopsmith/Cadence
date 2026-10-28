import Foundation

#if os(iOS)
import CoreMotion
#endif

/// One device-motion sample, in CoreMotion's units: g, rad/s, and radians.
public struct PhoneMotionReading {
    public var timestamp: TimeInterval
    public var userAccelerationG: (Double, Double, Double)
    public var gravityG: (Double, Double, Double)
    public var rotationRateRadPerSec: (Double, Double, Double)
    public var pitchRad: Double
    public var rollRad: Double

    public init(
        timestamp: TimeInterval,
        userAccelerationG: (Double, Double, Double),
        gravityG: (Double, Double, Double),
        rotationRateRadPerSec: (Double, Double, Double),
        pitchRad: Double,
        rollRad: Double
    ) {
        self.timestamp = timestamp
        self.userAccelerationG = userAccelerationG
        self.gravityG = gravityG
        self.rotationRateRadPerSec = rotationRateRadPerSec
        self.pitchRad = pitchRad
        self.rollRad = rollRad
    }

    /// Builds the IMU sample the gait and fall detectors already consume.
    ///
    /// Total acceleration keeps gravity, because the fall detector treats 1 g as
    /// rest and under 0.45 g as free fall. The vertical axis is aligned to
    /// gravity so a phone in a pocket does not depend on which way it is
    /// pointing, and `gy` is the rotation rate about gravity in rad/s.
    public func makeIMUSample() -> IMUSample {
        let ax = userAccelerationG.0 + gravityG.0
        let ay = userAccelerationG.1 + gravityG.1
        let az = userAccelerationG.2 + gravityG.2
        let gx = gravityG.0
        let gy = gravityG.1
        let gz = gravityG.2
        let gMag = sqrt(gx * gx + gy * gy + gz * gz)
        let pitchDeg = pitchRad * 180.0 / .pi
        let rollDeg = rollRad * 180.0 / .pi

        if gMag < 0.2 {
            return IMUSample(
                timestamp: timestamp,
                ax: ax, ay: ay, az: az,
                gx: rotationRateRadPerSec.0,
                gy: rotationRateRadPerSec.1,
                gz: rotationRateRadPerSec.2,
                pitchDeg: pitchDeg,
                rollDeg: rollDeg
            )
        }

        let vertical = (ax * gx + ay * gy + az * gz) / gMag
        let hx = ax - vertical * gx / gMag
        let hy = ay - vertical * gy / gMag
        let hz = az - vertical * gz / gMag
        let horizontal = sqrt(hx * hx + hy * hy + hz * hz)
        let yawRate = (
            rotationRateRadPerSec.0 * gx
            + rotationRateRadPerSec.1 * gy
            + rotationRateRadPerSec.2 * gz
        ) / gMag

        return IMUSample(
            timestamp: timestamp,
            ax: 0,
            ay: vertical,
            az: horizontal,
            gx: rotationRateRadPerSec.0,
            gy: yawRate,
            gz: rotationRateRadPerSec.2,
            pitchDeg: pitchDeg,
            rollDeg: rollDeg
        )
    }
}

/// Integrates yaw rate over the trailing 1.5 s. A turn in place is what the
/// upright-turn arm looks for; head bob while walking oscillates and cancels.
public struct YawTurnTracker {
    private var samples: [(t: Double, rate: Double)] = []
    private let windowSec = 1.5

    public init() {}

    public mutating func add(timestamp: Double, yawRateRadPerSec: Double) {
        samples.append((timestamp, yawRateRadPerSec))
        let cutoff = timestamp - windowSec
        if let firstKept = samples.firstIndex(where: { $0.t >= cutoff - 1e-9 }) {
            samples.removeFirst(firstKept)
        }
    }

    public func integratedDegrees() -> Double {
        guard samples.count >= 2 else { return 0 }
        var radians = 0.0
        for i in 1..<samples.count {
            let dt = samples[i].t - samples[i - 1].t
            guard dt > 0 else { continue }
            radians += 0.5 * (samples[i].rate + samples[i - 1].rate) * dt
        }
        return radians * 180.0 / .pi
    }
}

/// Fires once when a vertical surge and a pitch change follow 5 s of stillness.
/// The detector itself only opens the initiation window; this decides whether
/// the wearer actually stood up.
public struct SitToStandMonitor {
    private var stillHops = 0
    private var armed = false
    private var baselineAy = 0.0
    private var baselinePitch = 0.0

    public init() {}

    public mutating func update(totalEnergy: Double, ay: Double, pitchDeg: Double) -> Bool {
        if totalEnergy <= 0.02 {
            if stillHops == 0 && !armed {
                baselineAy = ay
                baselinePitch = pitchDeg
            }
            if !armed {
                stillHops += 1
                if stillHops >= 10 { armed = true }
            }
            return false
        }
        // A rise takes more than one hop to clear the surge thresholds. Stay
        // armed across those hops; only a real surge consumes it.
        if armed
            && (ay - baselineAy) > 0.35
            && abs(pitchDeg - baselinePitch) > 15.0 {
            armed = false
            stillHops = 0
            return true
        }
        if !armed { stillHops = 0 }
        return false
    }
}

/// Live iPhone motion. Unavailable on macOS and in tests; the conversion above
/// is what the detectors see, and it is tested without a device.
public final class PhoneMotionSource {
    public private(set) var isActive = false

    #if os(iOS)
    private let manager = CMMotionManager()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.cadence.phonemotion"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    #endif

    public init() {}

    public var isAvailable: Bool {
        #if os(iOS)
        return manager.isDeviceMotionAvailable
        #else
        return false
        #endif
    }

    public func start(_ onSample: @escaping (IMUSample) -> Void) {
        #if os(iOS)
        guard isAvailable, !isActive else { return }
        isActive = true
        manager.deviceMotionUpdateInterval = 0.01
        manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) { motion, _ in
            guard let motion else { return }
            let sample = PhoneMotionReading(
                timestamp: motion.timestamp,
                userAccelerationG: (
                    motion.userAcceleration.x,
                    motion.userAcceleration.y,
                    motion.userAcceleration.z
                ),
                gravityG: (motion.gravity.x, motion.gravity.y, motion.gravity.z),
                rotationRateRadPerSec: (
                    motion.rotationRate.x,
                    motion.rotationRate.y,
                    motion.rotationRate.z
                ),
                pitchRad: motion.attitude.pitch,
                rollRad: motion.attitude.roll
            ).makeIMUSample()
            DispatchQueue.main.async {
                onSample(sample)
            }
        }
        #else
        _ = onSample
        #endif
    }

    public func stop() {
        #if os(iOS)
        manager.stopDeviceMotionUpdates()
        #endif
        isActive = false
    }
}
