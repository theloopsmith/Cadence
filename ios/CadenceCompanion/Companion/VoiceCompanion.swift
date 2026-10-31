import Combine
import Foundation

public enum CompanionDestination: String, Identifiable {
    case motor, surroundings, medication, camera, diary, meal, settings, help
    public var id: String { rawValue }
}

public enum CompanionIntent: String, CaseIterable, Codable {
    case help, motor, medication, surroundings, logDose, undoDose, caregiver, emergency
    case camera, diary, meal, settings, start, skip, capture, usePhoto, retake, retry, finish, repeatPrompt
    case handoffMeta, cancel, stopListening, startProtection, stopProtection, unknown

    static func normalized(_ raw: String) -> String {
        raw.lowercased().replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: #"[^\p{L}\p{N}']+"#, with: " ", options: .regularExpression)
            .split(separator: " ").joined(separator: " ")
    }

    public static func parse(_ raw: String) -> CompanionIntent {
        let t = " " + normalized(raw) + " "
        func has(_ values: [String]) -> Bool { values.contains { t.contains(" " + $0 + " ") } }
        if has(["use hey meta", "let me use meta", "switch to meta", "release my glasses", "pause cadence"]) { return .handoffMeta }
        // A missed-reply phrase such as "I didn't get that" must never close a task.
        if has(["cancel", "never mind", "not now", "stop that", "don't call", "do not call",
                "didn't take my medication", "did not take my medication", "haven't taken my medication",
                "have not taken my medication", "didn't take my pill", "did not take my pill",
                "haven't taken my pill", "have not taken my pill"]) { return .cancel }
        if has(["stop listening", "turn off voice", "stop talking"]) { return .stopListening }
        if has(["call emergency", "call 911", "call an ambulance", "emergency services"]) { return .emergency }
        if has(["call my caregiver", "call caregiver", "call my care partner", "contact my caregiver", "caregiver", "my care partner"]) { return .caregiver }
        if has(["undo dose", "undo medication", "undo my last dose"]) { return .undoDose }
        if has(["i took my medication", "i took my medicine", "i took my pill", "i have taken my medication", "log my dose", "record my dose"]) { return .logDose }
        if has(["stop walking cues", "stop the beat", "stop protection"]) { return .stopProtection }
        if has(["start walking cues", "start protection", "help me walk"]) { return .startProtection }
        if has(["use this photo", "use photo", "save this photo"]) { return .usePhoto }
        if has(["retry", "try again", "retry this photo"]) { return .retry }
        if has(["retake", "take another photo"]) { return .retake }
        if has(["capture", "take a photo", "take the photo", "take a picture"]) { return .capture }
        if has(["skip", "skip this step", "skip this", "skip voice", "skip handwriting", "skip walk"]) { return .skip }
        if has(["finish", "done", "save my check", "finish early"]) { return .finish }
        if has(["repeat", "say that again", "what do i do next"]) { return .repeatPrompt }
        let motor = has(["motor exam", "motor check", "movement check"])
        let medication = has(["medication", "medications", "medicine", "my pills", "next dose"])
        let surroundings = has(["surroundings", "look around", "what do you see", "check the room", "around me"])
        if [motor, medication, surroundings].filter({ $0 }).count > 1 { return .help }
        if motor { return .motor }
        if medication { return .medication }
        if surroundings { return .surroundings }
        if has(["camera", "show live video"]) { return .camera }
        if has(["diary", "my day", "daily summary"]) { return .diary }
        if has(["log a meal", "record a meal", "meal time", "i ate"]) { return .meal }
        if has(["settings", "sign in", "server connection"]) { return .settings }
        if has(["start", "ready", "i'm ready", "i am ready", "let's begin", "begin"]) { return .start }
        if has(["help", "i need help", "help me", "hello", "hi cadence", "hey cadence"]) { return .help }
        return .unknown
    }

    public var needsConfirmation: Bool { [.logDose, .undoDose, .caregiver, .emergency, .startProtection, .stopProtection].contains(self) }
}

/// One conversation owns the everyday microphone. It yields to emergencies,
/// backgrounding, phonation measurement and other active voice flows.
@MainActor
public final class VoiceCompanion: ObservableObject {
    @Published public private(set) var isEnabled = false
    @Published public private(set) var status = "Voice companion is off"
    @Published public private(set) var lastHeard = ""
    @Published public private(set) var lastReply = ""
    @Published public var destination: CompanionDestination?
    @Published public private(set) var action: CompanionIntent = .unknown
    @Published public private(set) var actionID = UUID()
    @Published public private(set) var context: CompanionDestination?
    @Published public private(set) var step: CompanionStep = .general
    public var onMetaHandoff: (() -> Void)?
    private struct Flow { let id: UUID; let destination: CompanionDestination; var step: CompanionStep }
    private var flows: [Flow] = []
    private var flowRevision = UUID()
    public var execute: ((CompanionIntent) -> String)?
    public var understand: ((String, [String]) async -> CompanionIntent?)?
    public var onDisabled: (() -> Void)?
    private let listener: TranscriptListening
    private let speaker: PromptSpeaking
    private let echo: EchoGuarding
    private let debounceSeconds: Double
    private let promptDelaySeconds: Double
    private let confirmationWindowSeconds: Double
    private var pending: CompanionIntent?
    private var pauses: Set<String> = []
    private var generation = UUID()
    private var turn = UUID()
    private var task: Task<Void, Never>?
    private var healthTask: Task<Void, Never>?
    private var debounce: Task<Void, Never>?
    private var history: [String] = []

    public init(listener: TranscriptListening, speaker: PromptSpeaking, echo: EchoGuarding, debounceSeconds: Double = 0.8, promptDelaySeconds: Double = 0.35, confirmationWindowSeconds: Double = 20) {
        self.listener = listener; self.speaker = speaker; self.echo = echo
        self.debounceSeconds = max(0.001, debounceSeconds)
        self.promptDelaySeconds = max(0.001, promptDelaySeconds)
        self.confirmationWindowSeconds = max(0.001, confirmationWindowSeconds)
    }

    public func start() {
        history.removeAll(); lastHeard = ""
        isEnabled = true
        say("I'm here. Tell me what you need. I can help with your medication, surroundings, or a motor check.")
    }

    public func stop() {
        isEnabled = false; pending = nil; generation = UUID(); turn = UUID()
        task?.cancel(); debounce?.cancel(); healthTask?.cancel(); listener.stopListening(); speaker.cancel()
        status = "Voice companion is off"
        onDisabled?()
    }

    public func setPaused(_ reason: String, _ paused: Bool) {
        if paused { pauses.insert(reason) } else { pauses.remove(reason) }
        guard isEnabled else { return }
        generation = UUID(); turn = UUID(); pending = nil
        task?.cancel(); debounce?.cancel(); listener.stopListening()
        if pauses.isEmpty { listenAfterSpeech() }
        else { status = "Voice paused: " + pauses.sorted().joined(separator: ", ") }
    }

    public func releaseMicrophone(for reason: String) async {
        setPaused(reason, true)
        await listener.waitUntilStopped()
    }

    /// Compatibility entry point for non-presented contexts and tests.
    public func setContext(_ context: CompanionDestination?) {
        flows.removeAll()
        self.context = context
        step = .general
        flowDidChange()
    }

    public func enterFlow(id: UUID, destination: CompanionDestination, step: CompanionStep) {
        if let index = flows.firstIndex(where: { $0.id == id }) {
            flows[index].step = step
        } else { flows.append(Flow(id: id, destination: destination, step: step)) }
        restoreActiveFlow()
    }

    public func updateFlow(id: UUID, step: CompanionStep) {
        guard let index = flows.firstIndex(where: { $0.id == id }), flows[index].step != step else { return }
        flows[index].step = step
        // Updating a covered parent must not replace its camera child's context.
        if index == flows.count - 1 { restoreActiveFlow() }
    }

    public func leaveFlow(id: UUID) {
        guard let index = flows.firstIndex(where: { $0.id == id }) else { return }
        let wasActive = index == flows.count - 1
        flows.remove(at: index)
        if wasActive { restoreActiveFlow() }
    }

    private func restoreActiveFlow() {
        context = flows.last?.destination
        step = flows.last?.step ?? .general
        flowDidChange()
    }

    private func flowDidChange() {
        flowRevision = UUID(); pending = nil; turn = UUID()
        task?.cancel(); debounce?.cancel(); listener.stopListening()
        if isEnabled, pauses.isEmpty { listenAfterSpeech() }
    }

    public func handOffToMeta() {
        stop()
        onMetaHandoff?()
        status = "Cadence released the glasses. Use Hey Meta; tap Talk to Cadence to return."
    }

    public func say(_ text: String) {
        guard isEnabled, pauses.isEmpty else { return }
        turn = UUID(); task?.cancel(); debounce?.cancel(); listener.stopListening()
        lastReply = text; status = "Speaking"
        history.append("assistant: " + String(text.prefix(1000))); history = Array(history.suffix(6))
        if listener.waitsForMicrophoneReleaseBeforeSpeech {
            let turn = self.turn
            task = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.listener.waitUntilStopped()
                guard !Task.isCancelled, self.turn == turn, self.isEnabled, self.pauses.isEmpty else { return }
                guard self.speaker.speak(text) else { self.replyHeldByCues(); return }
                self.listenAfterSpeech()
            }
        } else {
            guard speaker.speak(text) else { replyHeldByCues(); return }
            listenAfterSpeech()
        }
    }

    /// Walking cues or the siren own the speaker. Say so instead of pretending
    /// the reply was heard, and do not open the microphone for a follow-up.
    private func replyHeldByCues() {
        status = "Walking cues are playing. I'll answer when they stop."
    }

    private func listenAfterSpeech() {
        let generation = self.generation
        task?.cancel()
        let delay = UInt64(promptDelaySeconds * 1_000_000_000)
        task = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            guard let self else { return }
            while self.echo.isInEchoWindow(at: Date()) {
                do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
                guard self.generation == generation, self.isEnabled, self.pauses.isEmpty else { return }
            }
            guard self.generation == generation, self.isEnabled, self.pauses.isEmpty else { return }
            self.openTurn()
        }
    }

    private func openTurn() {
        listener.stopListening()
        turn = UUID()
        let turn = self.turn
        status = "Listening"
        listener.startListening { [weak self] text in
            Task { @MainActor in
                guard let self, self.turn == turn, self.isEnabled, self.pauses.isEmpty,
                      !self.echo.isInEchoWindow(at: Date()) else { return }
                self.lastHeard = text
                self.debounce?.cancel()
                self.debounce = Task { @MainActor [weak self] in
                    guard let self else { return }
                    do { try await Task.sleep(nanoseconds: UInt64(self.debounceSeconds * 1_000_000_000)) } catch { return }
                    guard self.turn == turn else { return }
                    self.submit(text)
                }
            }
        }
        healthTask?.cancel()
        healthTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            guard let self, self.turn == turn, self.isEnabled, self.pauses.isEmpty else { return }
            if !self.listener.isListening {
                self.stop()
                self.status = "Microphone unavailable. Check audio and permissions, then try Talk to Cadence again."
            }
        }
        // Apple recognition tasks end periodically. Reopen between turns rather
        // than leaving a permanently lit microphone after the task has ended.
        task?.cancel()
        let timeout = UInt64((pending == nil ? 40 : confirmationWindowSeconds) * 1_000_000_000)
        task = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: timeout) } catch { return }
            guard let self, self.turn == turn, self.isEnabled, self.pauses.isEmpty else { return }
            if self.pending != nil { self.pending = nil; self.say("That confirmation timed out. Nothing was changed. What would you like to do?") }
            else { self.openTurn() }
        }
    }

    /// Complete user turn; partial transcripts are debounced before reaching here.
    public func submit(_ text: String) {
        guard isEnabled, pauses.isEmpty, !echo.isInEchoWindow(at: Date()) else { return }
        turn = UUID(); task?.cancel(); debounce?.cancel(); listener.stopListening()
        lastHeard = text
        let normalized = CompanionIntent.normalized(text)
        let parsed = CompanionIntent.parse(text)
        let intent = pending == nil ? (step.resolve(text) ?? parsed) : parsed
        if intent == .handoffMeta { handOffToMeta(); return }
        if intent == .cancel { pending = nil; publish(.cancel); say("Okay, I've stopped that. What else can I help with?"); return }
        if intent == .stopListening { stop(); return }
        if let pending {
            self.pending = nil
            if ["yes", "yes please", "confirm", "yes confirm", "please do"].contains(normalized) {
                say(execute?(pending) ?? "That action is unavailable.")
            } else if ["no", "no thanks", "no thank you"].contains(normalized) {
                say("Okay. Nothing was changed.")
            } else { say("I didn't get a clear confirmation. Nothing was changed. Tell me what you'd like to do.") }
            return
        }
        if intent == .unknown, ["yes", "yes please", "confirm", "no", "no thanks"].contains(normalized) {
            say(context == nil ? "What would you like me to help with?" : step.guidance); return
        }
        history.append("user: " + String(text.prefix(1000))); history = Array(history.suffix(6))
        if intent != .unknown { handle(intent); return }
        let generation = self.generation
        let revision = flowRevision
        status = "Thinking"
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            let intent = await self.understand?(text, self.history) ?? .unknown
            guard !Task.isCancelled, self.generation == generation, self.flowRevision == revision, self.isEnabled, self.pauses.isEmpty else { return }
            self.handle(intent)
        }
    }

    private func handle(_ intent: CompanionIntent) {
        if intent.needsConfirmation {
            pending = intent
            let question: String
            switch intent {
            case .logDose: question = "Just to check: you've taken your medication, and want me to record it now? Say yes or no."
            case .undoDose: question = "Would you like me to undo your last dose record? Say yes or no."
            case .caregiver: question = "Shall I open a call to your caregiver? Your phone may ask you to confirm the call. Say yes or no."
            case .emergency: question = "Shall I open a call to emergency services? Your phone may ask you to confirm the call. Say yes or no."
            case .startProtection: question = "Would you like me to turn on walking protection? Say yes or no."
            default: question = "Would you like me to stop walking cues and protection? Say yes or no."
            }
            say(question); return
        }
        switch intent {
        case .motor:
            if context == .motor { say(step.guidance); return }
            destination = .motor; say("Let's do your motor check, one step at a time. Say start when you're ready.")
        case .surroundings:
            if context == .surroundings { say(step.guidance); return }
            destination = .surroundings; say("Let's take a look together. Point your glasses toward what you want to check, then say take a photo.")
        case .medication: destination = .medication; say(execute?(.medication) ?? "Tell me if you'd like your next dose time, or want to record a dose you've taken.")
        case .camera: destination = .camera; say("Opening your glasses camera. Say capture when you're ready.")
        case .diary: destination = .diary; say(execute?(.diary) ?? "Here's your diary.")
        case .meal: destination = .meal; say("Opening your meal diary. Tell me when you're ready to record the meal time.")
        case .settings:
            if context == .surroundings { publish(.settings) } else { destination = .settings }
            say("Opening settings. Your care partner can help with setup and sign-in here.")
        case .repeatPrompt:
            if context != nil { say(step.guidance); return }
            say(lastReply.isEmpty ? "What can I help you with?" : lastReply)
        case .start, .skip, .capture, .usePhoto, .retake, .retry, .finish:
            if step == .analyzing { say(step.guidance); return }
            guard context != nil else { say("What would you like to start: a motor check, a surroundings check, or your camera?"); return }
            publish(intent); listenAfterSpeech()
        case .help:
            if context != nil { say(step.guidance); return }
            say("I'm here with you. What do you need help with: medication, your surroundings, a motor check, or contacting your caregiver?")
        default:
            if context != nil { say("I didn't quite catch that. " + step.guidance); return }
            say("I didn't quite catch what you need. We can check your surroundings, review your medication, or do a motor check. Which would help?")
        }
    }

    private func publish(_ intent: CompanionIntent) { action = intent; actionID = UUID() }
}
