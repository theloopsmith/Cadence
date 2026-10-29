import AVFoundation

/// Launch-configured priority audio engine (P0 Fall > P1 FoG Metronome > P2 Exam/Reality > P3 Nudge).
public final class AudioCueEngine: EchoGuarding {
    public static let shared = AudioCueEngine()
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let synthesizer = AVSpeechSynthesizer()
    private let pcmFormat = AVAudioFormat(standardFormatWithSampleRate: 44100.0, channels: 1)!
    public private(set) var isSirenActive: Bool = false
    public private(set) var isMetronomeActive: Bool = false

    /// Keeps the app alive in the background while protection runs.
    public private(set) lazy var keepAlive: SilentAudioKeepAlive = SilentAudioKeepAlive(engine: engine)

    /// A voice chosen in setup. Nil, or a voice that has been deleted, means
    /// "the most natural English voice installed".
    public var preferredVoiceIdentifier: String? {
        didSet { cachedVoice = nil }
    }
    private var cachedVoice: AVSpeechSynthesisVoice?

    /// When the app is speaking, and for a moment after. Listeners ignore the
    /// microphone in that window so the app never answers its own question.
    private var echoWindow = EchoWindow()
    private let echoLock = NSLock()
    private lazy var speechObserver = SpeechObserver(engine: self)

    private init() {
        configureLaunchAudioSession()
        synthesizer.delegate = speechObserver
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: pcmFormat)
        engine.mainMixerNode.outputVolume = 1.0
        playerNode.volume = 1.0
        ensureEngineRunning()
    }

    private func ensureEngineRunning() {
        guard !engine.isRunning else { return }
        do {
            try engine.start()
        } catch {
            print("AudioCueEngine engine.start() error: \(error)")
        }
    }

    /// Configured ONCE at app launch so siren activation never changes the session category.
    public func configureLaunchAudioSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        #if targetEnvironment(simulator)
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            print("Simulator audio session configuration error: \(error)")
        }
        #else
        do {
            var options: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
            #if swift(>=5.9)
            options.insert(.allowBluetoothHFP)
            #endif
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: options)
            try session.setActive(true)
            AudioRouteManager.shared.routeToGlassesIfAvailable()
        } catch {
            // Fallback for devices without bluetooth or microphone permissions
            try? session.setCategory(.playback, mode: .default)
            try? session.setActive(true)
        }
        #endif
        #endif
    }

    /// Priority 0: Forces 0 dBFS alternating 880/1760 Hz emergency siren out of the iPhone bottom speaker.
    public func activateBystanderSiren() {
        isMetronomeActive = false
        isSirenActive = true
        ensureEngineRunning()
        playerNode.stop()

        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.overrideOutputAudioPort(.speaker)
        #endif

        if let sirenBuffer = buildSirenPCMBuffer() {
            playerNode.scheduleBuffer(sirenBuffer, at: nil, options: .loops, completionHandler: nil)
            playerNode.play()
        }
    }

    /// Restores normal Bluetooth glasses routing after local siren cancellation.
    public func deactivateBystanderSiren() {
        isSirenActive = false
        playerNode.stop()
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.overrideOutputAudioPort(.none)
        #endif
    }

    /// Priority 1: Starts 100 BPM (1.67 Hz) Rhythmic Auditory Stimulation (RAS) metronome on glasses.
    public func startRASMetronome(bpm: Int = 100) {
        guard !isSirenActive else { return }
        isMetronomeActive = true
        ensureEngineRunning()
        playerNode.stop()

        if let clickBuffer = buildMetronomeClickPCMBuffer(bpm: bpm) {
            playerNode.scheduleBuffer(clickBuffer, at: nil, options: .loops, completionHandler: nil)
            playerNode.play()
        }
        speakPrompt("Step to the beat", priority: 1)
    }

    public func stopRASMetronome() {
        isMetronomeActive = false
        playerNode.stop()
    }

    /// Test tone and spoken confirmation to verify audio pipeline is audible.
    public func playAudioTest() {
        ensureEngineRunning()
        playerNode.stop()
        if let clickBuffer = buildMetronomeClickPCMBuffer(bpm: 100) {
            playerNode.scheduleBuffer(clickBuffer, at: nil, options: [], completionHandler: nil)
            playerNode.play()
        }
        speakPrompt("Cadence Audio System Online. All cues operational.", priority: 0)
    }

    /// Speaks a calm open-ear prompt respecting the 4-level priority hierarchy.
    public func speakPrompt(_ text: String, priority: Int = 2) {
        if isSirenActive && priority > 0 { return }
        if isMetronomeActive && priority > 1 { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = currentVoice()
        utterance.rate = 0.48
        utterance.pitchMultiplier = 1.0
        utterance.preUtteranceDelay = 0.05
        utterance.postUtteranceDelay = 0.05
        utterance.volume = (priority == 0) ? 1.0 : 0.85
        synthesizer.speak(utterance)
    }

    /// Generates a 1.0-second 0 dBFS alternating 880 Hz / 1760 Hz emergency siren PCM buffer.
    private func buildSirenPCMBuffer() -> AVAudioPCMBuffer? {
        let sampleRate = pcmFormat.sampleRate
        let frameCount = AVAudioFrameCount(sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: frameCount),
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
        let sampleRate = pcmFormat.sampleRate
        let secondsPerBeat = 60.0 / Double(max(40, min(200, bpm)))
        let frameCount = AVAudioFrameCount(sampleRate * secondsPerBeat)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: frameCount),
              let channelData = buffer.floatChannelData?[0] else {
            return nil
        }
        buffer.frameLength = frameCount
        let clickSamples = Int(0.025 * sampleRate) // 25ms crisp acoustic click
        for i in 0..<Int(frameCount) {
            if i < clickSamples {
                let env = exp(-Double(i) / (0.005 * sampleRate))
                let s1 = sin(2.0 * Double.pi * 880.0 * (Double(i) / sampleRate))
                let s2 = 0.5 * sin(2.0 * Double.pi * 1760.0 * (Double(i) / sampleRate))
                channelData[i] = Float(0.95 * env * (s1 + s2))
            } else {
                channelData[i] = 0.0
            }
        }
        return buffer
    }

    // MARK: - Voice

    /// The voice prompts are spoken in.
    public func currentVoice() -> AVSpeechSynthesisVoice? {
        if let cachedVoice { return cachedVoice }
        let chosen = VoiceSelection.best(from: VoiceCandidate.installed, preferred: preferredVoiceIdentifier)
        cachedVoice = chosen.flatMap { AVSpeechSynthesisVoice(identifier: $0.identifier) }
            ?? AVSpeechSynthesisVoice(language: "en-US")
        return cachedVoice
    }

    /// Plays a short sample in a given voice, for choosing one in setup.
    public func speakSample(voiceIdentifier: String) {
        let utterance = AVSpeechUtterance(string: "Hello. This is how Cadence will sound. Step with the beat.")
        utterance.voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) ?? currentVoice()
        utterance.rate = 0.48
        utterance.pitchMultiplier = 1.0
        utterance.preUtteranceDelay = 0.05
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer.speak(utterance)
    }

    // MARK: - Echo window

    public func isInEchoWindow(at date: Date) -> Bool {
        echoLock.lock(); defer { echoLock.unlock() }
        return synthesizer.isSpeaking || echoWindow.isActive(at: date)
    }

    fileprivate func speechDidStart() {
        echoLock.lock(); echoWindow.speechStarted(); echoLock.unlock()
    }

    fileprivate func speechDidEnd() {
        echoLock.lock(); echoWindow.speechEnded(at: Date()); echoLock.unlock()
    }
}

/// Receives the synthesizer's start and finish callbacks.
private final class SpeechObserver: NSObject, AVSpeechSynthesizerDelegate {
    private unowned let engine: AudioCueEngine

    init(engine: AudioCueEngine) {
        self.engine = engine
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        engine.speechDidStart()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        engine.speechDidEnd()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        engine.speechDidEnd()
    }
}
