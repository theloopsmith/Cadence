import Combine
import Foundation

public enum MotionHealth: Equatable { case off, starting, healthy, stale }

/// Owns the phone motion source and the shared sample engine, and publishes
/// what the screens render. The engine itself has no UI.
@MainActor
public final class MotionFeed: ObservableObject {
    @Published public private(set) var isRunning = false
    @Published public private(set) var lastFreezeIndex = 0.0
    @Published public private(set) var isFoGActive = false
    @Published public private(set) var armingMode = FoGArmingMode.disarmed.rawValue
    @Published public private(set) var fallEventUUID: String?
    @Published public private(set) var status = "Protection is off"
    @Published public private(set) var samplesSeen = 0
    @Published public private(set) var health: MotionHealth = .off
    public var staleAfterSec: TimeInterval = 2
    /// Which device the running stream comes from ("iPhone" or the glasses' name).
    @Published public private(set) var activeSourceLabel: String?

    public private(set) var activeCaptureSource: CaptureSource?
    public var streamID: UUID { sourceGeneration }
    public var onSourceWillStart: ((CaptureSource) -> Void)?

    public let phoneSource = PhoneMotionSource()
    private var source: MotionSource?
    private var engine: LiveEdgeEngine?
    private var locationLookup: (() -> LocationCoordinate?)?
    private let uptime: () -> TimeInterval
    private let automaticHealthChecks: Bool
    private var healthTimer: Timer?
    private var startedAt: TimeInterval?
    private var lastSampleAt: TimeInterval?
    private var lastSampleTimestamp: TimeInterval?
    private var sourceGeneration = UUID()

    /// Extra listeners for raw samples, e.g. the timed-walk recorder.
    private var sinks: [UUID: (IMUSample) -> Void] = [:]

    public init(uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, automaticHealthChecks: Bool = true) {
        self.uptime = uptime
        self.automaticHealthChecks = automaticHealthChecks
    }

    deinit { healthTimer?.invalidate() }

    public var sourceIsAvailable: Bool { phoneSource.isAvailable }

    public func attach(fogDetector: FoGDetector, fallDetector: FallDetector) {
        if engine == nil {
            engine = LiveEdgeEngine(fogDetector: fogDetector, fallDetector: fallDetector)
        }
    }

    public func beginSegment() {
        lastSampleTimestamp = nil
        engine?.beginSegment()
    }

    /// Registers a raw-sample listener. Returns a token for `removeSink`.
    @discardableResult
    public func addSink(_ sink: @escaping (IMUSample) -> Void) -> UUID {
        let token = UUID()
        sinks[token] = sink
        return token
    }

    public func removeSink(_ token: UUID) {
        sinks.removeValue(forKey: token)
    }

    @discardableResult
    public func ingest(
        _ sample: IMUSample,
        latitude: Double? = nil,
        longitude: Double? = nil,
        horizontalAccuracyM: Double? = nil
    ) -> LiveEdgeUpdate? {
        guard let engine else { return nil }
        // Invalid/duplicate timestamps must not keep a dead stream looking healthy.
        let fields = [sample.timestamp, sample.ax, sample.ay, sample.az, sample.gx, sample.gy, sample.gz, sample.pitchDeg, sample.rollDeg]
        guard fields.allSatisfy({ $0.isFinite }), lastSampleTimestamp.map({ sample.timestamp > $0 }) ?? true else { return nil }
        if isRunning, let lastSampleAt, uptime() - lastSampleAt > staleAfterSec {
            health = .stale
            discardStaleMotion()
        }
        lastSampleTimestamp = sample.timestamp
        if source != nil {
            lastSampleAt = uptime()
            if health != .healthy {
                health = .healthy
                status = "Motion samples are current"
            }
        }
        samplesSeen += 1
        for sink in sinks.values { sink(sample) }
        let update = engine.ingest(
            sample,
            latitude: latitude,
            longitude: longitude,
            horizontalAccuracyM: horizontalAccuracyM
        )
        apply(update)
        return update
    }

    /// Starts the phone's motion sensors. Returns whether the stream is running.
    @discardableResult
    public func startPhone(location: @escaping () -> LocationCoordinate?) -> Bool {
        start(source: phoneSource, label: "iPhone", location: location)
    }

    /// Starts streaming from `source`, stopping any other stream first.
    /// Returns whether the stream is running.
    @discardableResult
    public func start(
        source newSource: MotionSource,
        label: String,
        captureSource: CaptureSource = .phoneRecording,
        location: @escaping () -> LocationCoordinate?
    ) -> Bool {
        guard engine != nil else {
            status = "Motion engine is not ready."
            return false
        }
        if let source, source === newSource, source.isActive, health != .stale { return true }
        source?.stop()
        activeCaptureSource = captureSource
        onSourceWillStart?(captureSource)
        health = .starting
        discardStaleMotion()
        let generation = UUID()
        sourceGeneration = generation
        source = newSource
        startedAt = uptime()
        lastSampleAt = nil
        lastSampleTimestamp = nil
        health = .starting
        locationLookup = location
        newSource.start { [weak self] sample in
            guard let self, self.sourceGeneration == generation else { return }
            let loc = self.locationLookup?()
            _ = self.ingest(
                sample,
                latitude: loc?.latitude,
                longitude: loc?.longitude,
                horizontalAccuracyM: loc?.horizontalAccuracyM
            )
        }
        isRunning = newSource.isActive
        health = isRunning ? (lastSampleAt == nil ? .starting : .healthy) : .off
        activeSourceLabel = isRunning ? label : nil
        status = isRunning
            ? "Waiting for fresh motion samples"
            : "Motion sensors are not available on this device"
        healthTimer?.invalidate()
        if isRunning && automaticHealthChecks {
            healthTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.checkHealth() }
            }
        }
        return isRunning
    }

    public func stopSource() {
        sourceGeneration = UUID()
        healthTimer?.invalidate()
        healthTimer = nil
        source?.stop()
        source = nil
        isRunning = false
        health = .off
        lastSampleAt = nil
        lastSampleTimestamp = nil
        discardStaleMotion()
        isFoGActive = false
        activeSourceLabel = nil
        activeCaptureSource = nil
        status = "Protection is off"
    }

    public func stopPhone() {
        stopSource()
    }

    public func clearFall() {
        fallEventUUID = nil
    }

    public func checkHealth() {
        guard isRunning else { return }
        if source?.isActive != true || uptime() - (lastSampleAt ?? startedAt ?? uptime()) > staleAfterSec {
            if health != .stale {
                health = .stale
                discardStaleMotion()
            }
            status = "Motion input stopped. Protection is unavailable until fresh samples arrive."
        }
    }

    private func discardStaleMotion() {
        engine?.fogDetector.resetForStreamGap()
        engine?.fallDetector.resetForStreamGap()
        engine?.beginSegment()
        isFoGActive = false
        armingMode = FoGArmingMode.disarmed.rawValue
        // An already active fall check-in remains owned by FallAlertCoordinator.
    }

    private func apply(_ update: LiveEdgeUpdate) {
        if let freezeIndex = update.freezeIndex { lastFreezeIndex = freezeIndex }
        if let fogActive = update.fogActive { isFoGActive = fogActive }
        if let mode = update.armingMode { armingMode = mode }
        if let uuid = update.fallEventUUID { fallEventUUID = uuid }
    }
}
