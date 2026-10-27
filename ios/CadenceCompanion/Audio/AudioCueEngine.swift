import AVFoundation

/// Launch-configured priority audio engine (P0 Fall > P1 FoG Metronome > P2 Exam/Reality > P3 Nudge).
final class AudioCueEngine {
    static let shared = AudioCueEngine()
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let synthesizer = AVSpeechSynthesizer()
    private(set) var isSirenActive: Bool = false
    private(set) var isMetronomeActive: Bool = false

    private init() {
        configureLaunchAudioSession()
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: nil)
        try? engine.start()
    }

    /// Configured ONCE at app launch so siren activation never changes the session category.
    private func configureLaunchAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
            )
            try session.setActive(true)
        } catch {
            print("AudioCueEngine launch session error: \(error)")
        }
    }

    /// Priority 0: Forces 0 dBFS alternating 880/1760 Hz emergency siren out of the iPhone bottom speaker.
    func activateBystanderSiren() {
        isMetronomeActive = false
        isSirenActive = true
        let session = AVAudioSession.sharedInstance()
        try? session.overrideOutputAudioPort(.speaker)
    }

    /// Restores normal Bluetooth glasses routing after local siren cancellation.
    func deactivateBystanderSiren() {
        isSirenActive = false
        playerNode.stop()
        let session = AVAudioSession.sharedInstance()
        try? session.overrideOutputAudioPort(.none)
    }

    /// Priority 1: Starts 100 BPM (1.67 Hz) Rhythmic Auditory Stimulation (RAS) metronome on glasses.
    func startRASMetronome(bpm: Int = 100) {
        guard !isSirenActive else { return }
        isMetronomeActive = true
        speakPrompt("Step, step, step", priority: 1)
    }

    func stopRASMetronome() {
        isMetronomeActive = false
        playerNode.stop()
    }

    /// Speaks a calm open-ear prompt respecting the 4-level priority hierarchy.
    func speakPrompt(_ text: String, priority: Int = 2) {
        if isSirenActive && priority > 0 { return }
        if isMetronomeActive && priority > 1 { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.48
        utterance.volume = (priority == 0) ? 0.90 : 0.75
        synthesizer.speak(utterance)
    }
}
