import Combine
import Foundation

/// Everything the screens share. Built once at launch by `CadenceRootView`.
@MainActor
public final class CadenceAppModel: ObservableObject {
    public let settings: AppSettings
    public let motion: MotionFeed
    public let fallAlert: FallAlertCoordinator
    public let walking: WalkingModel
    public let glasses: GlassesSessionManager
    public let calibration: FoGCalibrationController
    public let recorder: LabeledCaptureRecorder
    public let exam: HomeMotorExamManager
    public let doses: DoseLogModel
    public let diary: DiaryStore
    public let transcripts: TranscriptListening
    public let haptics: HapticRouter
    public let voiceDose: VoiceDoseAssistant
    public let pillPhotos: PillPhotoStore
    public let offHours: OffHourLearner
    public let reminders: DoseReminderScheduler
    public let auth: AuthSession

    /// True while the mock glasses stand in for the real device.
    @Published public private(set) var isUsingMockGlasses = false
    /// Bumped whenever the diary changes so lists reload.
    @Published public private(set) var diaryVersion = 0
    /// Predicted off window from the schedule, or an hour the diary has
    /// learned freezes cluster in. Today drops to its essentials when true.
    @Published public private(set) var isSimpleMode = false
    /// The care partner's photo of the pill, if one was taken.
    @Published public private(set) var pillPhoto: Data?

    private var cancellables: Set<AnyCancellable> = []

    public convenience init() {
        self.init(
            settings: AppSettings(),
            motion: MotionFeed(),
            fallAlert: FallAlertCoordinator(),
            location: LiveLocationProvider.shared,
            captureStore: .default,
            diary: .default,
            transcripts: LiveTranscriptListener.shared,
            phoneHaptics: PhoneHaptics(),
            pillPhotos: .default,
            apiTransport: URLSessionJSONTransport(),
            notifications: SystemNotificationCenter()
        )
    }

    public init(
        settings: AppSettings,
        motion: MotionFeed,
        fallAlert: FallAlertCoordinator,
        location: LocationProvider,
        captureStore: LabeledCaptureStore,
        diary: DiaryStore,
        transcripts: TranscriptListening,
        phoneHaptics: HapticPatternPlaying,
        pillPhotos: PillPhotoStore,
        apiTransport: JSONTransporting,
        notifications: DoseNotificationCentering
    ) {
        settings.apiTransport = apiTransport
        self.settings = settings
        self.reminders = DoseReminderScheduler(center: notifications)
        let auth = AuthSession(settings: settings)
        self.auth = auth
        settings.sync.onUnauthorized = { [weak auth] in
            Task { @MainActor in auth?.markExpired() }
        }
        self.motion = motion
        self.fallAlert = fallAlert
        self.diary = diary
        self.transcripts = transcripts
        self.pillPhotos = pillPhotos
        self.pillPhoto = pillPhotos.load()
        self.offHours = OffHourLearner(diary: diary)
        let detector = FoGDetector()
        let glasses = GlassesSessionManager(phoneMotion: motion.phoneSource)
        self.glasses = glasses
        self.walking = WalkingModel(
            motion: motion, fallAlert: fallAlert, fogDetector: detector, location: location, glasses: glasses
        )
        self.calibration = FoGCalibrationController(store: captureStore, detector: detector)
        self.recorder = LabeledCaptureRecorder(motion: motion, store: captureStore, source: .phoneRecording)
        self.exam = HomeMotorExamManager()
        let doses = DoseLogModel(schedule: settings.schedule, diary: diary, sync: settings.sync)
        self.doses = doses
        self.haptics = HapticRouter(phone: phoneHaptics, glasses: glasses)
        self.voiceDose = VoiceDoseAssistant(doses: doses, listener: transcripts, speaker: AudioCueEngine.shared)
        settings.bind(fallAlert: fallAlert, exam: exam)
        calibration.recalibrate()
        refreshSimpleMode()

        // Signals the wearer feels: cue when the beat starts, reminder when a
        // dose comes due, alert when a check-in opens.
        motion.$isFoGActive
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in self?.haptics.play(.cue) }
            .store(in: &cancellables)

        doses.$isDoseDue
            .removeDuplicates()
            .dropFirst()
            .filter { $0 }
            .sink { [weak self] _ in
                self?.haptics.play(.reminder)
                self?.refreshSimpleMode()
            }
            .store(in: &cancellables)

        doses.$isSimpleMode
            .removeDuplicates()
            .sink { [weak self] _ in self?.refreshSimpleMode() }
            .store(in: &cancellables)

        fallAlert.$phase
            .sink { [weak self] phase in
                if case .checkIn = phase { self?.haptics.play(.alert) }
            }
            .store(in: &cancellables)

        settings.$schedule
            .dropFirst()
            .sink { [weak self] schedule in
                guard let self else { return }
                self.doses.schedule = schedule
                Task { await self.reminders.sync(schedule) }
            }
            .store(in: &cancellables)

        // A logged dose withdraws today's reminder for it.
        doses.$takenToday
            .dropFirst()
            .scan(([Date](), [Date]())) { ($0.1, $1) }
            .sink { [weak self] previous, current in
                guard let self, current.count > previous.count, let latest = current.last else { return }
                self.reminders.doseTaken(at: latest, schedule: self.settings.schedule)
            }
            .store(in: &cancellables)

        // A confirmed impact opens the check-in; the overlay follows `fallAlert.phase`.
        motion.$fallEventUUID
            .compactMap { $0 }
            .sink { [weak self] uuid in
                guard let self else { return }
                self.fallAlert.beginCheckIn(eventUUID: uuid)
                self.motion.clearFall()
            }
            .store(in: &cancellables)

        // Diary lines for the moments the glasses handle.
        motion.$isFoGActive
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] active in
                guard let self, !active, !self.walking.isDemoRunning else { return }
                self.record(.cue, detail: "A steady beat helped you step again")
            }
            .store(in: &cancellables)

        motion.$isRunning
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] running in
                self?.record(running ? .protectionOn : .protectionOff, detail: "")
            }
            .store(in: &cancellables)

        fallAlert.$lastOutcome
            .compactMap { $0 }
            .sink { [weak self] outcome in
                switch outcome {
                case "canceled_false_alarm":
                    self?.record(.checkInAnswered, detail: "You said you were okay")
                case "canceled_by_user_button":
                    self?.record(.checkInAnswered, detail: "You tapped I'm OK")
                case "confirmed_waiting_dispatch":
                    self?.record(.helpSent, detail: "Your caregiver was contacted")
                default:
                    break
                }
            }
            .store(in: &cancellables)

        doses.$takenToday
            .dropFirst()
            .sink { [weak self] _ in self?.diaryVersion += 1 }
            .store(in: &cancellables)

        // Child objects do not bubble changes through a parent automatically.
        for publisher in [
            settings.objectWillChange.eraseToAnyPublisher(),
            motion.objectWillChange.eraseToAnyPublisher(),
            fallAlert.objectWillChange.eraseToAnyPublisher(),
            walking.objectWillChange.eraseToAnyPublisher(),
            glasses.objectWillChange.eraseToAnyPublisher(),
            calibration.objectWillChange.eraseToAnyPublisher(),
            recorder.objectWillChange.eraseToAnyPublisher(),
            exam.objectWillChange.eraseToAnyPublisher(),
            doses.objectWillChange.eraseToAnyPublisher(),
            voiceDose.objectWillChange.eraseToAnyPublisher(),
            auth.objectWillChange.eraseToAnyPublisher(),
        ] {
            publisher.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        }
    }

    private func record(_ kind: DiaryEventKind, detail: String) {
        try? diary.append(DiaryEvent(kind: kind, at: Date(), detail: detail))
        diaryVersion += 1
        if kind == .cue { refreshSimpleMode() }
    }

    /// Developer override; nil means "follow the prediction".
    public var forcedSimpleMode: Bool? {
        didSet { refreshSimpleMode() }
    }

    private func refreshSimpleMode() {
        if let forced = forcedSimpleMode {
            isSimpleMode = forced
            return
        }
        isSimpleMode = doses.isSimpleMode || offHours.isLearnedOffHour(Date())
    }

    /// Diary access for tools that log outside the automatic hooks.
    public func recordDiary(_ kind: DiaryEventKind, detail: String, at date: Date = Date()) {
        try? diary.append(DiaryEvent(kind: kind, at: date, detail: detail))
        diaryVersion += 1
    }

    public func diaryChanged() {
        diaryVersion += 1
    }

    /// Saves the care partner's pill photo for the medication card.
    public func setPillPhoto(_ jpeg: Data?) {
        if let jpeg {
            try? pillPhotos.save(jpeg)
        } else {
            try? pillPhotos.remove()
        }
        pillPhoto = pillPhotos.load()
    }

    /// Attaches real glasses supplied by the host app (the toolkit adapter).
    /// Replaces any mock. Connection is attempted when protection starts or
    /// the wearer taps Connect.
    public func attachGlasses(_ device: GlassesDevice) {
        glasses.attach(device)
        isUsingMockGlasses = false
        realGlasses = device
    }

    /// The real device handed in by the host app, kept so the mock toggle
    /// can hand control back to it.
    private var realGlasses: GlassesDevice?

    /// Attaches the mock glasses, which loop reference walking motion and
    /// report "worn" on connect. Useful without hardware; turning it off
    /// restores the real device if one was attached.
    public func useMockGlasses(_ enabled: Bool) {
        if enabled {
            let walking = LabeledCaptureLibrary.referenceCaptures().first { $0.label == .walking }?.samples ?? []
            let device = MockGlassesDevice(
                name: "Ray-Ban Meta (mock)",
                loopSamples: walking,
                frame: MockGlassesDevice.sampleFrameJPEG
            )
            glasses.attach(device)
            isUsingMockGlasses = true
        } else if let realGlasses {
            glasses.attach(realGlasses)
            isUsingMockGlasses = false
        } else {
            glasses.detach()
            isUsingMockGlasses = false
        }
    }

    /// A Muse Voice Transcribe listener for one purpose. The server holds the
    /// Meta key; the phone only sends short clips while it is listening.
    private func cloudEarFactory(
        for purpose: CadenceAPIClient.TranscribePurpose
    ) -> (@escaping (String) -> Void) -> CloudEar {
        { [weak self] onTranscript in
            CloudEar(
                transcribe: { [weak self] wav in
                    guard let self else { return nil }
                    let request: (CadenceAPIClient, [String])? = await MainActor.run {
                        guard self.settings.cloudListeningEnabled else { return nil }
                        let keywords = purpose == .dose ? [self.settings.schedule.medicationName] : []
                        return (self.settings.api, keywords)
                    }
                    guard let (client, keywords) = request else { return nil }
                    return try? await client.transcribe(wav: wav, purpose: purpose, keywords: keywords)
                },
                onTranscript: onTranscript
            )
        }
    }

    /// Called once the first screen appears.
    public func start() {
        LiveSpeechCheckInListener.shared.cloudEarFactory = cloudEarFactory(for: .fallCheckIn)
        LiveTranscriptListener.shared.cloudEarFactory = cloudEarFactory(for: .dose)
        AudioCueEngine.shared.configureLaunchAudioSession()
        LiveLocationProvider.shared.requestAuthorization()
        if settings.protectionEnabled {
            walking.setProtection(enabled: true)
        }
        Task { await reminders.sync(settings.schedule) }
    }
}
