import Combine
import Foundation

/// Everything the screens share. Built once at launch by `CadenceRootView`.
@MainActor
public final class CadenceAppModel: ObservableObject {
    public static let shared = CadenceAppModel()
    @Published public private(set) var persistenceWarning: String?
    @Published public private(set) var profileResetError: String?
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
    private var deliveryTask: Task<Void, Never>?

    public convenience init() {
        let profile = DeviceProfile.shared
        self.init(
            settings: AppSettings(profile: profile),
            motion: MotionFeed(),
            fallAlert: FallAlertCoordinator(),
            location: LiveLocationProvider.shared,
            captureStore: LabeledCaptureStore(directory: profile.directory.appendingPathComponent("Captures")),
            diary: DiaryStore(directory: profile.directory.appendingPathComponent("Diary")),
            transcripts: LiveTranscriptListener.shared,
            phoneHaptics: PhoneHaptics(),
            pillPhotos: PillPhotoStore(directory: profile.directory.appendingPathComponent("Medication")),
            apiTransport: URLSessionJSONTransport(),
            notifications: SystemNotificationCenter(),
            history: TaskMetricsHistory(directory: profile.directory.appendingPathComponent("MotorChecks"))
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
        notifications: DoseNotificationCentering,
        history: TaskMetricsHistory? = nil
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
        detector.eventSync = settings.sync
        let glasses = GlassesSessionManager(phoneMotion: motion.phoneSource)
        self.glasses = glasses
        self.walking = WalkingModel(
            motion: motion, fallAlert: fallAlert, fogDetector: detector, location: location, glasses: glasses
        )
        self.calibration = FoGCalibrationController(store: captureStore, detector: detector)
        self.recorder = LabeledCaptureRecorder(motion: motion, store: captureStore, source: .phoneRecording)
        self.exam = HomeMotorExamManager(sync: settings.sync, history: history)
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
                self?.deliveryTask?.cancel()
                if case .dispatched = phase { self?.startDeliveryMonitoring() }
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

        settings.sync.onPersistenceFailure = { [weak self, weak fallAlert] error in
            Task { @MainActor in
                self?.persistenceWarning = error.message
                fallAlert?.persistenceWarning = error.message
            }
        }
        settings.sync.onPersistenceRecovered = { [weak self, weak fallAlert] in
            Task { @MainActor in self?.persistenceWarning = nil; fallAlert?.persistenceWarning = nil }
        }
        if let error = settings.sync.persistenceError {
            persistenceWarning = error.message
            fallAlert.persistenceWarning = error.message
        }
        // Diary lines for the moments the glasses handle.
        motion.$isFoGActive
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] active in
                guard let self, !active, !self.walking.isDemoRunning, self.motion.health == .healthy else { return }
                self.record(.cue, detail: "Walking cue ended while motion samples were current")
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
                    self?.record(.helpSent, detail: "Help requested; caregiver receipt is unverified", incidentID: self?.fallAlert.activeEventUUID)
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

    deinit { deliveryTask?.cancel() }

    private func startDeliveryMonitoring() {
        guard let eventUUID = fallAlert.activeEventUUID else { return }
        let client = settings.api
        guard !client.bearerToken.isEmpty else { return }
        deliveryTask = Task { [weak self] in
            while !Task.isCancelled {
                guard await self?.refreshDelivery(eventUUID: eventUUID, client: client) == true else { return }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    @discardableResult
    func refreshDelivery(eventUUID: String, client: CadenceAPIClient) async -> Bool {
        func stillOwned() -> Bool {
            !client.bearerToken.isEmpty && !settings.restartRequired && fallAlert.isDispatched && fallAlert.activeEventUUID == eventUUID &&
                settings.deviceToken == client.bearerToken && settings.api.baseURL == client.baseURL
        }
        guard stillOwned() else { return false }
        do {
            let reply = try await client.fallDelivery(eventUUID: eventUUID)
            guard stillOwned(), reply.eventUUID == eventUUID else { return false }
            let before = fallAlert.contactState
            fallAlert.updateDelivery(reply)
            if before != fallAlert.contactState {
                if reply.providerAccepted && before != "provider_accepted" && before != "acknowledged" {
                    record(.alertAccepted, detail: "Provider accepted this alert; caregiver receipt is not confirmed", incidentID: eventUUID)
                }
                if reply.caregiverAcknowledged && fallAlert.contactState == "acknowledged" {
                    record(.caregiverAcknowledged, detail: "The server verified a caregiver acknowledgment for this alert", incidentID: eventUUID)
                }
            }
        } catch { /* Keep the last observed state; offline is not proof of delivery. */ }
        return stillOwned()
    }

    private func record(_ kind: DiaryEventKind, detail: String, incidentID: String? = nil) {
        guard !settings.restartRequired else { return }
        let id = incidentID.map { "\(kind.rawValue)-\($0)" } ?? UUID().uuidString
        try? diary.append(DiaryEvent(id: id, kind: kind, at: Date(), detail: detail, incidentID: incidentID))
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
        guard !settings.restartRequired else { return }
        try? diary.append(DiaryEvent(kind: kind, at: date, detail: detail))
        diaryVersion += 1
    }

    public func diaryChanged() {
        diaryVersion += 1
    }

    /// Saves the care partner's pill photo for the medication card.
    public func setPillPhoto(_ jpeg: Data?) {
        guard !settings.restartRequired else { return }
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
        glasses.connect()
    }

    /// The real device handed in by the host app, kept so the mock toggle
    /// can hand control back to it.
    private var realGlasses: GlassesDevice?

    /// Attaches the mock glasses, which loop reference walking motion and
    /// report "worn" on connect. Useful without hardware; turning it off
    /// restores the real device if one was attached.
    public func attachMockKit(samples: [IMUSample]) {
        settings.backendBaseURL = "http://127.0.0.1:18063"
        settings.deviceToken = ""
        settings.cloudListeningEnabled = false
        settings.protectionEnabled = false
        walking.setProtection(enabled: false)
        glasses.attach(MockGlassesDevice(name: "Cadence Mock Kit — simulated sensors", loopSamples: samples))
        isUsingMockGlasses = true
        glasses.connect()
        // A mock launch must not start audible cues without a deliberate action.
    }

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
        guard !settings.restartRequired, settings.profile.failure == nil else { return }
        LiveSpeechCheckInListener.shared.cloudEarFactory = cloudEarFactory(for: .fallCheckIn)
        LiveTranscriptListener.shared.cloudEarFactory = cloudEarFactory(for: .dose)
        AudioCueEngine.shared.configureLaunchAudioSession()
        LiveLocationProvider.shared.requestAuthorization()
        if settings.protectionEnabled {
            walking.setProtection(enabled: true)
        }
        Task { await reminders.sync(settings.schedule) }
    }

    @discardableResult
    public func resetLocalProfile() -> Bool {
        guard !fallAlert.isAlertVisible else {
            profileResetError = "Resolve the active help alert before erasing this phone's profile."
            return false
        }
        do {
            guard try settings.prepareLocalReset() else {
                profileResetError = "An upload is still in progress. Wait for it to finish, then try erasing again."
                return false
            }
        } catch {
            profileResetError = "The reset could not be saved safely. Check phone storage and try again."
            return false
        }
        auth.cancelPendingSignIn()
        deliveryTask?.cancel()
        voiceDose.cancel()
        exam.cancelExam()
        walking.stopWalkingAudio()
        glasses.detach()
        _ = recorder.stopAndSave()
        reminders.suspendForLocalReset()
        AudioCueEngine.shared.cancelSpeech()
        pillPhoto = nil
        profileResetError = nil
        return true
    }
}
