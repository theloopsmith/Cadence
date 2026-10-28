import Combine
import Foundation

/// What the Home screen shows about walking: whether protection is on,
/// what the phone sees, whether a cue is playing, and the labeled demo.
@MainActor
public final class WalkingModel: ObservableObject {
    @Published public private(set) var isProtectionOn = false
    @Published public private(set) var isCueing = false
    @Published public private(set) var headline = "Protection is off"
    @Published public private(set) var detail = "Turn on protection to listen for freezes while you walk."
    @Published public private(set) var isDemoRunning = false
    @Published public private(set) var demoProgress = 0.0
    @Published public private(set) var lastDemoSummary: String?
    /// Seconds the cue played during the last demo. Nil before any demo.
    @Published public private(set) var lastDemoCueSeconds: Double?

    /// Shown next to every demo control so nobody mistakes it for the live path.
    public let demoLabel = "Demo"
    /// Pacing for the demo playback; tests set this to zero.
    public var demoSampleIntervalNs: UInt64 = 20_000_000

    public let fogDetector: FoGDetector
    public let fallAlert: FallAlertCoordinator
    public let motion: MotionFeed
    public let glasses: GlassesSessionManager
    private let location: LocationProvider
    private let keepAlive: BackgroundKeepAliving
    private var cancellables: Set<AnyCancellable> = []
    private var demoTask: Task<Void, Never>?

    public init(
        motion: MotionFeed,
        fallAlert: FallAlertCoordinator,
        fogDetector: FoGDetector = FoGDetector(),
        location: LocationProvider,
        glasses: GlassesSessionManager? = nil,
        keepAlive: BackgroundKeepAliving? = nil
    ) {
        self.motion = motion
        self.fallAlert = fallAlert
        self.fogDetector = fogDetector
        self.location = location
        self.keepAlive = keepAlive ?? AudioCueEngine.shared.keepAlive
        self.glasses = glasses ?? GlassesSessionManager(phoneMotion: motion.phoneSource)
        motion.attach(fogDetector: fogDetector, fallDetector: fallAlert.detector)
        fallAlert.wearStateProvider = self.glasses

        // When the glasses connect or drop while protection is on, move the
        // stream to the best available source without the wearer doing anything.
        self.glasses.$connectionState
            .dropFirst()
            .sink { [weak self] _ in
                guard let self, self.motion.isRunning, !self.isDemoRunning else { return }
                self.setProtection(enabled: true)
            }
            .store(in: &cancellables)

        motion.$isFoGActive
            .combineLatest(motion.$armingMode, motion.$isRunning)
            .sink { [weak self] cueing, mode, running in
                self?.isCueing = cueing
                self?.isProtectionOn = running
                self?.refreshText(armingMode: mode, cueing: cueing, running: running)
            }
            .store(in: &cancellables)
    }

    // MARK: - Protection

    public func setProtection(enabled: Bool) {
        if enabled {
            let source = glasses.preferredMotionSource
            let label = glasses.preferredSourceLabel
            let started = motion.start(source: source, label: label) { [location] in location.currentLocation }
            if started {
                keepAlive.start()
            } else {
                keepAlive.stop()
                headline = source.isAvailable
                    ? "Protection could not start"
                    : "Motion sensors are not available on this device"
                detail = label == "iPhone"
                    ? "Cadence listens through your iPhone's motion sensors. Keep the phone in a pocket while you walk."
                    : "The glasses did not start their motion stream. Try reconnecting them."
            }
        } else {
            motion.stopPhone()
            keepAlive.stop()
            if fogDetector.isEpisodeActive {
                AudioCueEngine.shared.stopRASMetronome()
            }
        }
    }

    // MARK: - Demo (labeled)

    /// Plays the reference walk → freeze → recovery through the real detector
    /// so the cue and its stop can be heard without a real freeze. Protection
    /// is paused while it plays so live samples do not mix with the demo.
    public func startFreezeDemo() {
        guard !isDemoRunning else { return }
        let wasProtected = motion.isRunning
        motion.stopPhone()
        motion.beginSegment()
        isDemoRunning = true
        demoProgress = 0
        lastDemoSummary = nil

        let samples = IMUScenarioReplayer.generateSamples(scenario: .freezeOfGaitWithRecovery, sampleRateHz: 50)
        let interval = demoSampleIntervalNs
        demoTask = Task { [weak self] in
            var cueSeconds = 0.0
            var cueStartedAt: Double?
            for (index, sample) in samples.enumerated() {
                guard let self, !Task.isCancelled else { return }
                let update = self.motion.ingest(sample)
                if update?.fogActive == true, cueStartedAt == nil { cueStartedAt = sample.timestamp }
                if update?.fogActive == false, let started = cueStartedAt {
                    cueSeconds = sample.timestamp - started
                    cueStartedAt = nil
                }
                if index % 10 == 0 {
                    self.demoProgress = Double(index) / Double(samples.count)
                }
                if interval > 0 { try? await Task.sleep(nanoseconds: interval) }
            }
            guard let self, !Task.isCancelled else { return }
            if let started = cueStartedAt { cueSeconds = samples.last!.timestamp - started }
            self.lastDemoCueSeconds = cueSeconds
            self.finishDemo(summary: cueSeconds > 0
                ? String(format: "Demo finished. The beat played for %.0f seconds and stopped when walking resumed.", cueSeconds)
                : "Demo finished without a cue. Check the calibration in Settings.")
            if wasProtected { self.setProtection(enabled: true) }
        }
    }

    public func stopFreezeDemo() {
        demoTask?.cancel()
        demoTask = nil
        finishDemo(summary: "Demo stopped.")
    }

    private func finishDemo(summary: String) {
        isDemoRunning = false
        demoProgress = 1
        lastDemoSummary = summary
        AudioCueEngine.shared.stopRASMetronome()
        motion.beginSegment()
        isCueing = false
    }

    // MARK: - Text

    /// Which device is listening right now, for the status line.
    public var sourceSentence: String {
        guard let label = motion.activeSourceLabel else { return "" }
        return label == "iPhone" ? "Listening through your iPhone." : "Listening through \(label)."
    }

    private func refreshText(armingMode: String, cueing: Bool, running: Bool) {
        guard running || isDemoRunning else {
            headline = "Protection is off"
            detail = "Turn on protection to listen for freezes while you walk."
            return
        }
        headline = cueing ? "Beat playing" : (isDemoRunning ? "Demo playing" : "Protection is on")
        detail = detailForTesting(armingMode: armingMode, cueing: cueing)
    }

    /// Plain-language description of the current state. Exposed so the words
    /// can be tested without a sensor.
    public func detailForTesting(armingMode: String, cueing: Bool) -> String {
        if cueing { return "Playing a steady beat to help you step" }
        switch FoGArmingMode(rawValue: armingMode) ?? .disarmed {
        case .walking: return "Walking steadily"
        case .sitToStand: return "Standing up"
        case .turningUpright: return "Turning"
        case .disarmed: return "Standing or sitting"
        }
    }
}
