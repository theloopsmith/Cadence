import Combine
import Foundation

/// What the wearer meant, read tolerantly from soft or partial speech.
public enum DoseVoiceIntent: Equatable {
    case taken
    case yes
    case no
    case unclear

    private static let takenWords = ["taken", "took", "had my", "have had", "i've had", "swallowed"]
    private static let yesWords = ["yes", "yeah", "yep", "yup", "correct", "that's right", "thats right", "i did", "right"]
    private static let noWords = ["no", "nope", "not yet", "haven't", "havent", "didn't", "didnt", "wrong"]

    public static func parse(_ raw: String) -> DoseVoiceIntent {
        let text = " " + FallDetector.normalizeTranscript(raw).trimmingCharacters(in: .whitespaces) + " "
        guard text.trimmingCharacters(in: .whitespaces).count > 0 else { return .unclear }
        // Refusals first: "no I haven't taken it" is a no.
        if noWords.contains(where: { text.contains(" \($0) ") }) { return .no }
        if takenWords.contains(where: { text.contains(" \($0) ") || text.contains(" \($0)") && $0.count > 4 }) {
            return .taken
        }
        if yesWords.contains(where: { text.contains(" \($0) ") }) { return .yes }
        return .unclear
    }
}

/// Logs a dose by voice with a readback. One question at a time, a long
/// silence window, and no scolding. Nothing is written until the wearer
/// confirms.
@MainActor
public final class VoiceDoseAssistant: ObservableObject {
    public enum State: Equatable { case idle, listening, confirming, done, cancelled }

    @Published public private(set) var state: State = .idle
    @Published public private(set) var lastHeard = ""

    /// How long to wait for speech before ending gently.
    public var silenceWindowSec: TimeInterval

    private let doses: DoseLogModel
    private let listener: TranscriptListening
    private let speaker: PromptSpeaking
    private var silenceTask: Task<Void, Never>?
    private var lastTranscript = ""

    public init(
        doses: DoseLogModel,
        listener: TranscriptListening,
        speaker: PromptSpeaking,
        silenceWindowSec: TimeInterval = 20
    ) {
        self.doses = doses
        self.listener = listener
        self.speaker = speaker
        self.silenceWindowSec = silenceWindowSec
    }

    public func begin() {
        guard state == .idle || state == .done || state == .cancelled else { return }
        state = .listening
        lastTranscript = ""
        lastHeard = ""
        speaker.speak("Have you taken your \(doses.schedule.medicationName)? Say taken when you have.")
        listener.startListening { [weak self] text in
            self?.heard(text)
        }
        armSilence()
    }

    public func cancel() {
        silenceTask?.cancel()
        listener.stopListening()
        state = .idle
    }

    private func heard(_ transcript: String) {
        // Partial results grow the same sentence; act on what is new.
        let fresh: String
        if transcript.hasPrefix(lastTranscript) {
            fresh = String(transcript.dropFirst(lastTranscript.count))
        } else {
            fresh = transcript
        }
        lastTranscript = transcript
        lastHeard = transcript
        let intent = DoseVoiceIntent.parse(fresh.isEmpty ? transcript : fresh)
        armSilence()

        switch (state, intent) {
        case (.listening, .taken), (.listening, .yes):
            state = .confirming
            lastTranscript = transcript
            speaker.speak("You took your \(doses.schedule.medicationName) just now. Is that right? Yes or no.")
        case (.listening, .no):
            finish(.cancelled, saying: "No problem. Log it when you can.")
        case (.listening, .unclear):
            speaker.speak("Say taken when you have had it, or say no if not yet.")
        case (.confirming, .yes), (.confirming, .taken):
            doses.markTaken()
            Haptics.success()
            finish(.done, saying: "Logged. Thank you.")
        case (.confirming, .no):
            finish(.cancelled, saying: "No problem. Nothing was logged.")
        case (.confirming, .unclear):
            speaker.speak("Just yes or no. Did you take it?")
        default:
            break
        }
    }

    private func armSilence() {
        silenceTask?.cancel()
        let window = silenceWindowSec
        silenceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(window * 1_000_000_000))
            guard !Task.isCancelled, let self, self.state == .listening || self.state == .confirming else { return }
            self.finish(.cancelled, saying: "No problem. Log it when you can.")
        }
    }

    private func finish(_ end: State, saying text: String) {
        silenceTask?.cancel()
        listener.stopListening()
        state = end
        speaker.speak(text)
    }
}
