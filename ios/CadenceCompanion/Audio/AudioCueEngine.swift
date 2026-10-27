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
        playerNode.stop()

        let session = AVAudioSession.sharedInstance()
        try? session.overrideOutputAudioPort(.speaker)

        if let sirenBuffer = buildSirenPCMBuffer() {
            playerNode.scheduleBuffer(sirenBuffer, at: nil, options: .loops, completionHandler: nil)
            playerNode.play()
        }
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
        playerNode.stop()

        if let clickBuffer = buildMetronomeClickPCMBuffer(bpm: bpm) {
            playerNode.scheduleBuffer(clickBuffer, at: nil, options: .loops, completionHandler: nil)
            playerNode.play()
        }
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

    /// Generates a 1.0-second 0 dBFS alternating 880 Hz / 1760 Hz emergency siren PCM buffer.
    private func buildSirenPCMBuffer() -> AVAudioPCMBuffer? {
        let sampleRate = 44100.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            return nil
        }
        let frameCount = AVAudioFrameCount(sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channelData = buffer.floatChannelData?[0] else {
            return nil
        }
        buffer.frameLength = frameCount
        let halfFrames = Int(frameCount) / 2
        for i in 0..<Int(frameCount) {
            let freq = (i < halfFrames) ? 880.0 : 1760.0
            let phase = 2.0 * Double.pi * freq * (Double(i) / sampleRate)
            channelData[i] = Float(sin(phase)) // 0 dBFS full-scale amplitude (1.0)
        }
        return buffer
    }

    /// Generates one period of a crisp 100 BPM (0.60s per beat) woodblock click PCM buffer.
    private func buildMetronomeClickPCMBuffer(bpm: Int) -> AVAudioPCMBuffer? {
        let sampleRate = 44100.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            return nil
        }
        let secondsPerBeat = 60.0 / Double(max(40, min(200, bpm)))
        let frameCount = AVAudioFrameCount(sampleRate * secondsPerBeat)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channelData = buffer.floatChannelData?[0] else {
            return nil
        }
        buffer.frameLength = frameCount
        let clickSamples = Int(0.018 * sampleRate) // 18ms crisp acoustic click
        for i in 0..<Int(frameCount) {
            if i < clickSamples {
                let env = exp(-Double(i) / (0.004 * sampleRate))
                let phase = 2.0 * Double.pi * 1000.0 * (Double(i) / sampleRate)
                channelData[i] = Float(0.85 * env * sin(phase))
            } else {
                channelData[i] = 0.0
            }
        }
        return buffer
    }
}
