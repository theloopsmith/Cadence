import Combine
import Foundation
import AVFoundation
import Speech

/// Everything the screens share. Built once at launch by `CadenceRootView`.
@MainActor
public final class CadenceAppModel: ObservableObject {
    public static let shared = CadenceAppModel()
    @Published public private(set) var persistenceWarning: String?
    @Published public private(set) var profileResetError: String?
    @Published public private(set) var syncNotice: String?
    /// Set when today's diary could not be written. A fall that was escalated
    /// must not silently vanish from the Diary tab.
    @Published public private(set) var diaryWarning: String?
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
    public let companion: VoiceCompanion
    @Published public private(set) var isUsingMetaAssistant = false
    @Published public private(set) var isHandingOffToMeta = false
    @Published public private(set) var metaHandoffError: String?
    @Published public private(set) var voicePermissionError: String?
    private var voiceActivationID = UUID()
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
        settings.onUnauthorized = { [weak auth] in auth?.markExpired() }
        settings.sync.onUnauthorized = { [weak auth] in
            Task { @MainActor in auth?.markExpired() }
        }
        self.motion = motion
        self.fallAlert = fallAlert
        self.diary = diary
        self.transcripts = transcripts
        self.pillPhotos = pillPhotos
        self.pillPhotoOwner = settings.schedule.medicationName
        let scopedPhoto = pillPhotos.forMedication(settings.schedule.medicationName)
        var initialPhoto = scopedPhoto.load()
        var migrationError: String?
        do {
            if settings.medications.count == 1, initialPhoto == nil, let legacy = pillPhotos.load() {
                try scopedPhoto.save(legacy)
                initialPhoto = legacy
            }
            // Retain the original file separately; it must never be assigned to
            // a different medication on a later single-medication launch.
            try pillPhotos.archiveLegacy()
        } catch { migrationError = "The previous medication photo could not be migrated. Check phone storage." }
        self.pillPhoto = initialPhoto
        self.photoSaveError = migrationError
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
        self.companion = VoiceCompanion(listener: transcripts, speaker: AudioCueEngine.shared, echo: AudioCueEngine.shared)
        settings.bind(fallAlert: fallAlert, exam: exam)
        companion.confirmationPrompt = { [weak self] intent in
            guard intent == .logDose, let self else { return nil }
            return "Have you taken \(self.settings.schedule.medicationName) and want to record it now? Say yes or no."
        }
        companion.execute = { [weak self] intent in self?.executeCompanionAction(intent) ?? "That action is unavailable." }
        companion.onDisabled = { [weak self] in
            if self?.companion.preservesVoicePreferenceOnStop != true { self?.settings.voiceCompanionEnabled = false }
            self?.voiceDose.cancel()
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.transcripts.waitUntilStopped()
                // A rapid off/on must not release a newly acquired conversation.
                if !self.companion.isEnabled { AudioCueEngine.shared.releaseMicrophoneSession(owner: .companion) }
            }
        }
        companion.onMetaHandoff = { [weak self] in Task { @MainActor in await self?.useMetaAssistant() } }
        companion.understand = { [weak self] text, history in
            guard let self, self.settings.cloudListeningEnabled, !self.auth.needsSignIn else { return nil }
            let client = self.settings.api
            let result = try? await client.companionIntent(text: text, history: history)
            guard self.settings.deviceToken == client.bearerToken, self.settings.api.baseURL == client.baseURL,
                  !self.settings.restartRequired else { return nil }
            return result
        }
        motion.onSourceWillStart = { [weak controller = self.calibration] source in controller?.recalibrate(for: source) }
        calibration.recalibrate(for: .phoneRecording)
        refreshSimpleMode()
        settings.sync.onServerDataErased = { [weak self] in
            Task { @MainActor in
                self?.syncNotice = "Server data was erased. Older pending changes were discarded. Your local diary is still on this phone."
                self?.fallAlert.serverDataWasErased()
                self?.companion.setPaused("Server data changed", true)
                self?.companion.setPaused("Server data changed", false)
            }
        }

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
                guard let self else { return }
                // A fall alert preempts the optional Hey Meta handoff. Restore
                // Cadence audio before the coordinator opens its check-in mic.
                let alertIsActive: Bool
                if case .idle = phase { alertIsActive = false } else { alertIsActive = true }
                if self.isUsingMetaAssistant && alertIsActive {
                    AudioCueEngine.shared.retryAudio()
                    self.isUsingMetaAssistant = false
                }
                if case .idle = phase { self.companion.setPaused("Safety check-in", false) }
                else { self.companion.setPaused("Safety check-in", true) }
                if case .checkIn = phase {
                    self.haptics.play(.alert)
                    // Only one microphone owner during a check-in: an exam voice
                    // step or its live level monitor would hold the input engine
                    // and the wearer's spoken answer would never be heard.
                    if self.exam.isRunning { self.exam.cancelExam() }
                    VoiceMonitor.shared.stopLiveMonitoring()
                }
                self.deliveryTask?.cancel()
                if case .dispatched = phase { self.startDeliveryMonitoring() }
            }
            .store(in: &cancellables)

        voiceDose.$state.removeDuplicates().sink { [weak self] state in
            self?.companion.setPaused("Dose confirmation", state == .listening || state == .confirming)
        }.store(in: &cancellables)

        settings.$schedule
            .dropFirst()
            .sink { [weak self] schedule in
                guard let self else { return }
                self.doses.schedule = schedule
                if self.pillPhotoOwner != schedule.medicationName {
                    if let photo = self.pillPhoto {
                        do { try self.pillPhotos.forMedication(self.pillPhotoOwner).save(photo) }
                        catch { self.photoSaveError = "The previous medication photo could not be saved. Check phone storage." }
                    }
                    self.pillPhotoOwner = schedule.medicationName
                    self.pillPhoto = self.pillPhotos.forMedication(schedule.medicationName).load()
                }
                self.voiceDose.cancel()
                self.companion.setPaused("Medication changed", true)
                self.companion.setPaused("Medication changed", false)
            }
            .store(in: &cancellables)

        settings.$medications.removeDuplicates(by: { a, b in
            a.sorted { $0.medicationName < $1.medicationName } == b.sorted { $0.medicationName < $1.medicationName }
        }).dropFirst().sink { [weak self] plan in
            Task { await self?.syncMedicationReminders(plan) }
        }.store(in: &cancellables)

        doses.onDoseTaken = { [weak self] date, schedule in
            self?.reminders.doseTaken(at: date, schedule: schedule)
        }

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
            companion.objectWillChange.eraseToAnyPublisher(),
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
                && settings.sync.currentDataGeneration == client.dataGeneration
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
        appendToDiary(DiaryEvent(id: id, kind: kind, at: Date(), detail: detail, incidentID: incidentID))
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
        appendToDiary(DiaryEvent(kind: kind, at: date, detail: detail))
        diaryVersion += 1
    }

    private func appendToDiary(_ event: DiaryEvent) {
        do {
            try diary.append(event)
            diaryWarning = nil
        } catch {
            diaryWarning = "Today's diary could not be saved on this phone. Check storage. Help and calls still work."
        }
    }

    public func diaryChanged() {
        diaryVersion += 1
    }

    /// Saves the care partner's pill photo for the medication card.
    @Published public private(set) var photoSaveError: String?
    private var pillPhotoOwner = ""
    private var pendingPillPhoto: (data: Data?, pending: Bool, owner: String) = (nil, false, "")

    public func setPillPhoto(_ jpeg: Data?, medicationName: String? = nil) {
        guard !settings.restartRequired else { return }
        pendingPillPhoto = (jpeg, true, medicationName ?? settings.schedule.medicationName)
        retryPillPhotoSave()
    }

    public func retryPillPhotoSave() {
        guard !settings.restartRequired, pendingPillPhoto.pending else { return }
        do {
            let store = pillPhotos.forMedication(pendingPillPhoto.owner)
            if let data = pendingPillPhoto.data { try store.save(data) }
            else { try store.remove() }
            if pendingPillPhoto.owner == settings.schedule.medicationName { pillPhoto = pendingPillPhoto.data }
            pendingPillPhoto = (nil, false, "")
            photoSaveError = nil
        } catch {
            photoSaveError = "The medication photo could not be saved on this phone. Keep Cadence open and retry saving."
        }
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
        glasses.attach(MockGlassesDevice(name: "Cadence Mock Kit — simulated sensors", loopSamples: samples, frame: MockGlassesDevice.sampleFrameJPEG))
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

    private var voiceWasBackgrounded = false
    @Published public private(set) var isStartingVoice = false

    public var voiceStatusText: String {
        if isUsingMetaAssistant { return "Using Hey Meta" }
        if companion.isEnabled { return companion.status }
        if isStartingVoice { return "Starting voice companion…" }
        if voicePermissionError != nil { return "Voice needs attention" }
        if settings.voiceCompanionEnabled {
            if fallAlert.isAlertVisible { return "Voice paused for the safety check-in" }
            return companion.status == "Voice companion is off" ? "Voice waiting to start" : companion.status
        }
        return "Voice is turned off in Settings"
    }

    public func voiceSceneChanged(isActive: Bool, isBackground: Bool) {
        // Siri can overlay this foreground app without sending it to background.
        if isBackground || (!isActive && isUsingMetaAssistant) { voiceWasBackgrounded = true }
        companion.setPaused("App in background", !isActive)
        guard isActive, voiceWasBackgrounded else { return }
        voiceWasBackgrounded = false
        if settings.voiceCompanionEnabled, !companion.isEnabled {
            Task { await enableVoiceCompanion() }
        }
    }

    public func enableVoiceCompanion() async {
        guard !settings.restartRequired, !fallAlert.isAlertVisible, !isHandingOffToMeta, !isStartingVoice else { return }
        isStartingVoice = true
        defer { isStartingVoice = false }
        let activationID = UUID()
        voiceActivationID = activationID
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        let microphone = await AVCaptureDevice.requestAccess(for: .audio)
        guard voiceActivationID == activationID, !isHandingOffToMeta else { return }
        guard !settings.restartRequired, !fallAlert.isAlertVisible else { return }
        guard speech, microphone else {
            voicePermissionError = "Allow Microphone and Speech Recognition for Cadence in iPhone Settings to use the voice companion."
            return
        }
        // This tap is also the explicit recovery action after a route failure.
        AudioCueEngine.shared.retryAudio()
        guard AudioCueEngine.shared.prepareMicrophoneSession(owner: .companion) else {
            voicePermissionError = AudioCueEngine.shared.audioProblem ?? "The microphone could not start. Check audio, then retry."
            return
        }
        if isUsingMetaAssistant { glasses.connect() }
        isUsingMetaAssistant = false; metaHandoffError = nil
        voicePermissionError = nil
        settings.voiceCompanionEnabled = true
        companion.start()
    }

    public func useMetaAssistant() async {
        guard !isHandingOffToMeta, !isUsingMetaAssistant else { return }
        guard !fallAlert.isAlertVisible else {
            metaHandoffError = "Finish the active safety check-in before switching to Hey Meta."
            return
        }
        isHandingOffToMeta = true
        voiceActivationID = UUID()
        defer { isHandingOffToMeta = false }
        companion.stop(preservePreference: true)
        companion.destination = nil
        if exam.isRunning { exam.cancelExam() }
        glasses.stopCameraPreview()
        glasses.disconnect()
        await transcripts.waitUntilStopped()
        guard !fallAlert.isAlertVisible, !companion.isEnabled else { return }
        do {
            try AudioCueEngine.shared.releaseForMetaAssistant()
            isUsingMetaAssistant = true
            metaHandoffError = nil
        } catch {
            metaHandoffError = "The glasses audio route could not be released. Close Cadence before using Hey Meta."
        }
    }

    private func executeCompanionAction(_ intent: CompanionIntent) -> String {
        guard !settings.restartRequired, !fallAlert.isAlertVisible else { return "Let's finish the current safety check-in first." }
        switch intent {
        case .medication:
            if let error = doses.saveError { return error }
            let schedule = settings.schedule
            guard !schedule.isEmpty else { return "Your medication plan isn't set up yet. Ask your caregiver to add the prescribed name and times in setup." }
            let formatter = DateFormatter(); formatter.timeStyle = .short; formatter.calendar = schedule.calendar
            let next = schedule.dueDose(at: Date(), takenToday: doses.takenToday) ?? schedule.nextDose(after: Date())
            let timing = next.map { "Your saved time for \(schedule.medicationName) is \(formatter.string(from: $0))." } ?? "There isn't another saved medication time."
            let last = doses.lastDoseTaken.map { " The last dose you recorded was at \(formatter.string(from: $0))." } ?? ""
            return timing + last + " If you've already taken it, tell me and I can record it. I won't change your prescribed dose."
        case .logDose:
            guard !settings.schedule.isEmpty else { return "Your medication plan isn't set up yet. Ask your caregiver to add the prescribed name and times first." }
            guard doses.markTaken() else { return doses.saveError ?? "I couldn't save that dose. Nothing was logged. Please try again." }
            return doses.saveError ?? "I've recorded that you've taken \(settings.schedule.medicationName)."
        case .undoDose:
            guard doses.canUndo else { return "There isn't a dose I can undo from this session." }
            guard doses.undo() else { return doses.saveError ?? "I couldn't undo that record. Please try again." }
            return "I've undone the last dose record on this phone."
        case .caregiver:
            guard settings.hasCaregiver else { return "There isn't a caregiver number saved yet. Ask your care partner to add one in settings." }
            fallAlert.callCaregiver()
            return "Opening your caregiver's number. Your phone may ask you to confirm the call."
        case .emergency:
            fallAlert.callEmergencyServices()
            return "Opening emergency services. Your phone may ask you to confirm the call."
        case .startProtection:
            settings.protectionEnabled = true; walking.setProtection(enabled: true)
            return walking.headline
        case .stopProtection:
            settings.protectionEnabled = false; walking.setProtection(enabled: false)
            return "Walking protection and its cues are stopped."
        case .diary:
            return (try? diary.plainFacts(for: Date()).joined(separator: ". ")) ?? "I couldn't read today's diary. Please check your phone's storage."
        default: return "What would you like help with?"
        }
    }

    private func syncMedicationReminders(_ plan: [MedicationSchedule]) async {
        await reminders.sync(plan)
        guard settings.medications.sorted(by: { $0.medicationName < $1.medicationName }) == plan.sorted(by: { $0.medicationName < $1.medicationName }) else { return }
        do {
            let events = try diary.events(on: Date())
            for medication in plan {
                for event in events where event.kind == .doseTaken && event.detail == medication.medicationName {
                    reminders.doseTaken(at: event.at, schedule: medication)
                }
            }
        } catch { diaryWarning = "Medication history could not be read. Reminder suppression could not be checked." }
    }

    /// Called once the first screen appears.
    public func start() {
        guard !settings.restartRequired, settings.profile.failure == nil else { return }
        LiveSpeechCheckInListener.shared.cloudEarFactory = cloudEarFactory(for: .fallCheckIn)
        LiveTranscriptListener.shared.cloudEarFactory = cloudEarFactory(for: .companion)
        AudioCueEngine.shared.configureLaunchAudioSession()
        LiveLocationProvider.shared.requestAuthorization()
        if settings.voiceCompanionEnabled { Task { await enableVoiceCompanion() } }
        if settings.protectionEnabled {
            walking.setProtection(enabled: true)
        }
        Task { await syncMedicationReminders(settings.medications) }
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
        companion.stop()
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
