import Combine
import Foundation

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
    /// Which device the running stream comes from ("iPhone" or the glasses' name).
    @Published public private(set) var activeSourceLabel: String?

    public let phoneSource = PhoneMotionSource()
    private var source: MotionSource?
    private var engine: LiveEdgeEngine?
    private var locationLookup: (() -> LocationCoordinate?)?

    /// Extra listeners for raw samples, e.g. the timed-walk recorder.
    private var sinks: [UUID: (IMUSample) -> Void] = [:]

    public init() {}

    public var sourceIsAvailable: Bool { phoneSource.isAvailable }

    public func attach(fogDetector: FoGDetector, fallDetector: FallDetector) {
        if engine == nil {
            engine = LiveEdgeEngine(fogDetector: fogDetector, fallDetector: fallDetector)
        }
    }

    public func beginSegment() {
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
        location: @escaping () -> LocationCoordinate?
    ) -> Bool {
        guard engine != nil else {
            status = "Motion engine is not ready."
            return false
        }
        if let source, source === newSource, source.isActive { return true }
        source?.stop()
        source = newSource
        locationLookup = location
        newSource.start { [weak self] sample in
            guard let self else { return }
            let loc = self.locationLookup?()
            _ = self.ingest(
                sample,
                latitude: loc?.latitude,
                longitude: loc?.longitude,
                horizontalAccuracyM: loc?.horizontalAccuracyM
            )
        }
        isRunning = newSource.isActive
        activeSourceLabel = isRunning ? label : nil
        status = isRunning
            ? "Protection on — watching for freezes and falls"
            : "Motion sensors are not available on this device"
        return isRunning
    }

    public func stopSource() {
        source?.stop()
        source = nil
        isRunning = false
        isFoGActive = false
        activeSourceLabel = nil
        status = "Protection is off"
    }

    public func stopPhone() {
        stopSource()
    }

    public func clearFall() {
        fallEventUUID = nil
    }

    private func apply(_ update: LiveEdgeUpdate) {
        if let freezeIndex = update.freezeIndex { lastFreezeIndex = freezeIndex }
        if let fogActive = update.fogActive { isFoGActive = fogActive }
        if let mode = update.armingMode { armingMode = mode }
        if let uuid = update.fallEventUUID { fallEventUUID = uuid }
    }
}
