import Combine
import Foundation

/// Everything the screens share. Built once at launch by `CadenceRootView`.
@MainActor
public final class CadenceAppModel: ObservableObject {
    public let settings: AppSettings
    public let motion: MotionFeed
    public let fallAlert: FallAlertCoordinator
    public let walking: WalkingModel
    public let calibration: FoGCalibrationController
    public let recorder: LabeledCaptureRecorder
    public let exam: HomeMotorExamManager

    private var cancellables: Set<AnyCancellable> = []

    public convenience init() {
        self.init(
            settings: AppSettings(),
            motion: MotionFeed(),
            fallAlert: FallAlertCoordinator(),
            location: LiveLocationProvider.shared,
            captureStore: .default
        )
    }

    public init(
        settings: AppSettings,
        motion: MotionFeed,
        fallAlert: FallAlertCoordinator,
        location: LocationProvider,
        captureStore: LabeledCaptureStore
    ) {
        self.settings = settings
        self.motion = motion
        self.fallAlert = fallAlert
        let detector = FoGDetector()
        self.walking = WalkingModel(motion: motion, fallAlert: fallAlert, fogDetector: detector, location: location)
        self.calibration = FoGCalibrationController(store: captureStore, detector: detector)
        self.recorder = LabeledCaptureRecorder(motion: motion, store: captureStore, source: .phoneRecording)
        self.exam = HomeMotorExamManager()
        settings.bind(fallAlert: fallAlert, exam: exam)
        calibration.recalibrate()

        // A confirmed impact opens the check-in; the overlay follows `fallAlert.phase`.
        motion.$fallEventUUID
            .compactMap { $0 }
            .sink { [weak self] uuid in
                guard let self else { return }
                self.fallAlert.beginCheckIn(eventUUID: uuid)
                self.motion.clearFall()
            }
            .store(in: &cancellables)

        // Child objects do not bubble changes through a parent automatically.
        for publisher in [
            settings.objectWillChange.eraseToAnyPublisher(),
            motion.objectWillChange.eraseToAnyPublisher(),
            fallAlert.objectWillChange.eraseToAnyPublisher(),
            walking.objectWillChange.eraseToAnyPublisher(),
            calibration.objectWillChange.eraseToAnyPublisher(),
            recorder.objectWillChange.eraseToAnyPublisher(),
        ] {
            publisher.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        }
    }

    /// Called once the first screen appears.
    public func start() {
        AudioCueEngine.shared.configureLaunchAudioSession()
        LiveLocationProvider.shared.requestAuthorization()
        if settings.protectionEnabled {
            walking.setProtection(enabled: true)
        }
    }
}
