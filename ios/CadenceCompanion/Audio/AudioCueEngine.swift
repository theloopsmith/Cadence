import AVFoundation
import Combine
import Foundation

extension Notification.Name { static let cadenceAudioPaused = Notification.Name("CadenceAudioPaused") }

/// Launch-configured priority audio engine (P0 Fall > P1 FoG Metronome > P2 Exam/Reality > P3 Nudge).
public final class AudioCueEngine: ObservableObject, EchoGuarding {
    public static let shared = AudioCueEngine()
    private lazy var engine = AVAudioEngine()
    private lazy var playerNode = AVAudioPlayerNode()
    private lazy var synthesizer = AVSpeechSynthesizer()
    private let pcmFormat = AVAudioFormat(standardFormatWithSampleRate: 44100.0, channels: 1)!
    @Published public private(set) var isAudioAvailable = true
    @Published public private(set) var audioProblem: String?
    @Published public private(set) var isInterrupted = false
    public private(set) var isSirenActive: Bool = false
    public private(set) var isMetronomeActive: Bool = false

    /// Keeps the app alive in the background while protection runs.
    public private(set) lazy var keepAlive: BackgroundKeepAliving = playbackEnabled ? SilentAudioKeepAlive(engine: engine) : TestKeepAlive()
    // Only explicit unit-test runs suppress hardware playback, never the normal app.
    private let playbackEnabled: Bool
    private let engineStarter: (() throws -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var prompts = PromptArbiter()
    private var utteranceIDs: [ObjectIdentifier: UUID] = [:]
    private var metronomeBPM = 100
    private var awaitingExplicitResume = false
    private var resumeAfterInterruption = false
    private var resetRequiresUserAction = false
    private var sessionConfigured = false
    private(set) var mediaServicesGeneration = 0

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

    init(playbackEnabled: Bool? = nil, engineStarter: (() throws -> Void)? = nil) {
        self.playbackEnabled = playbackEnabled ?? !(ProcessInfo.processInfo.environment["CADENCE_TEST_SILENT_AUDIO"] == "1" && NSClassFromString("XCTestCase") != nil)
        self.engineStarter = engineStarter
        guard self.playbackEnabled else { return }
        let sessionReady = configureLaunchAudioSession()
        synthesizer.delegate = speechObserver
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: pcmFormat)
        engine.mainMixerNode.outputVolume = 1.0
        playerNode.volume = 1.0
        if sessionReady { _ = ensureEngineRunning() }
        observeAudioSession()
    }

    @discardableResult
    private func ensureEngineRunning() -> Bool {
        guard !isInterrupted, !awaitingExplicitResume else { return false }
        guard !playbackEnabled || sessionConfigured else { return false }
        do {
            if let engineStarter { try engineStarter() }
            else if playbackEnabled && !engine.isRunning { try engine.start() }
            isAudioAvailable = true
            audioProblem = nil
            return true
        } catch {
            isAudioAvailable = false
            audioProblem = "Audio could not start. Check the route and tap Retry audio."
            return false
        }
    }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    private func observeAudioSession() {
        #if os(iOS)
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            if type == .began { self?.interruptionBegan() }
            else {
                let flags = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                self?.interruptionEnded(shouldResume: AVAudioSession.InterruptionOptions(rawValue: flags).contains(.shouldResume))
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in self?.mediaServicesReset() })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] notification in
            guard let self, let changed = notification.object as? AVAudioEngine, changed === self.engine else { return }
            if !self.engine.isRunning && (self.isSirenActive || self.isMetronomeActive || self.keepAlive.isActive) {
                self.pauseOutput(reason: "Audio configuration changed. Check the route and tap Retry audio.")
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] notification in
            AudioRouteManager.shared.updateCurrentInput()
            let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            if AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable {
                // Do not unexpectedly move an earphone cue to a different speaker.
                self?.outputDeviceDisconnected()
            }
        })
        #endif
    }

    private func pauseOutput(reason: String) {
        let alreadyPaused = awaitingExplicitResume
        awaitingExplicitResume = true
        isAudioAvailable = false
        sessionConfigured = false
        audioProblem = reason
        guard !alreadyPaused else { return }
        cancelSpeech()
        NotificationCenter.default.post(name: .cadenceAudioPaused, object: self)
        if playbackEnabled { playerNode.stop(); (keepAlive as? SilentAudioKeepAlive)?.suspend(); engine.pause() }
    }

    func interruptionBegan() {
        if !isInterrupted { resumeAfterInterruption = !awaitingExplicitResume }
        isInterrupted = true
        pauseOutput(reason: "Audio interrupted. Cues are unavailable until audio resumes.")
    }

    func outputDeviceDisconnected() {
        pauseOutput(reason: "Audio device disconnected. Check the route and tap Retry audio.")
    }

    func interruptionEnded(shouldResume: Bool) {
        isInterrupted = false
        if shouldResume && resumeAfterInterruption && !resetRequiresUserAction { retryAudio() }
        else { audioProblem = "Audio paused. Tap Retry audio when ready." }
    }

    func mediaServicesReset() {
        resetRequiresUserAction = true
        mediaServicesGeneration += 1
        pauseOutput(reason: "Audio services restarted. Tap Retry audio when ready.")
        guard playbackEnabled else { return }
        engine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()
        synthesizer = AVSpeechSynthesizer()
        synthesizer.delegate = speechObserver
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: pcmFormat)
        engine.mainMixerNode.outputVolume = 1
        playerNode.volume = 1
        (keepAlive as? SilentAudioKeepAlive)?.rebuild(using: engine)
        // No automatic playback after a media-services reset.
    }

    public func retryAudio() {
        guard !isInterrupted else { return }
        resetRequiresUserAction = false
        awaitingExplicitResume = false
        guard configureLaunchAudioSession(), ensureEngineRunning() else { return }
        (keepAlive as? SilentAudioKeepAlive)?.resumeIfRequested()
        if isSirenActive { playSiren() }
        else if isMetronomeActive { playMetronome() }
        AudioRouteManager.shared.updateCurrentInput()
    }

    /// Clear all speech, including queued utterances. Stale delegates cannot
    /// complete a replacement prompt because each utterance carries its own ID.
    public func cancelSpeech() {
        _ = prompts.cancel()
        utteranceIDs.removeAll()
        if playbackEnabled { synthesizer.stopSpeaking(at: .immediate) }
        speechDidEnd()
    }

    public func cancelNonEmergencySpeech() {
        if let active = prompts.active, active.priority > 0 { cancelSpeech() }
    }

    var activePromptText: String? { prompts.active?.text }

    private func cancelCueSpeech() {
        if prompts.cancel(priority: 1) {
            utteranceIDs.removeAll()
            if playbackEnabled { synthesizer.stopSpeaking(at: .immediate) }
            speechDidEnd()
        }
    }

    /// Reconfigure after an explicit retry or an interrupt that permits resuming.
    @discardableResult
    public func configureLaunchAudioSession(preferVoiceChat: Bool = true, requiresInput: Bool = false) -> Bool {
        guard !isInterrupted, !awaitingExplicitResume else { return false }
        guard playbackEnabled else { sessionConfigured = true; return true }
        sessionConfigured = false
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        #if targetEnvironment(simulator)
        do {
            try session.setCategory(requiresInput ? .playAndRecord : .playback, mode: requiresInput ? .measurement : .default, options: requiresInput ? [.mixWithOthers, .defaultToSpeaker] : [.mixWithOthers])
            try session.setActive(true)
        } catch {
            if requiresInput {
                isAudioAvailable = false
                audioProblem = "Microphone audio could not start. Check permissions and the audio route."
                return false
            }
            isAudioAvailable = false
            audioProblem = "Audio session could not start. Tap Retry audio."
            return false
        }
        #else
        do {
            var options: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
            #if swift(>=5.9)
            options.insert(.allowBluetoothHFP)
            #endif
            try session.setCategory(.playAndRecord, mode: preferVoiceChat ? .voiceChat : .default, options: options)
            try session.setActive(true)
            AudioRouteManager.shared.routeToGlassesIfAvailable()
        } catch {
            // Fallback for devices without bluetooth or microphone permissions
            if requiresInput {
                isAudioAvailable = false
                audioProblem = "Microphone audio could not start. Check permissions and the audio route."
                return false
            }
            do {
                try session.setCategory(.playback, mode: .default)
                try session.setActive(true)
            } catch {
                isAudioAvailable = false
                audioProblem = "Audio session could not start. Tap Retry audio."
                return false
            }
        }
        #endif
        #endif
        AudioRouteManager.shared.updateCurrentInput()
        sessionConfigured = true
        return true
    }

    /// Microphone setup runs on worker queues; session policy and published
    /// health remain on the main thread. Hardware taps still open off-main.
    func prepareMicrophoneSession() -> Bool {
        if Thread.isMainThread { return configureLaunchAudioSession(requiresInput: true) }
        return DispatchQueue.main.sync { self.configureLaunchAudioSession(requiresInput: true) }
    }

    func currentMediaServicesGeneration() -> Int {
        if Thread.isMainThread { return mediaServicesGeneration }
        return DispatchQueue.main.sync { self.mediaServicesGeneration }
    }

    public func checkOutputHealth() {
        if playbackEnabled && !isInterrupted && !awaitingExplicitResume &&
            (isSirenActive || isMetronomeActive || (keepAlive as? SilentAudioKeepAlive)?.isRequested == true) && !engine.isRunning {
            pauseOutput(reason: "Audio output stopped. Tap Retry audio when ready.")
        }
    }

    /// Priority 0: Forces 0 dBFS alternating 880/1760 Hz emergency siren out of the iPhone bottom speaker.
    public func activateBystanderSiren() {
        cancelSpeech()
        isMetronomeActive = false
        isSirenActive = true
        playSiren()
    }

    private func playSiren() {
        guard ensureEngineRunning(), playbackEnabled else { return }
        playerNode.stop()
        #if os(iOS)
        do { try AVAudioSession.sharedInstance().overrideOutputAudioPort(.speaker) }
        catch { isAudioAvailable = false; audioProblem = "Emergency speaker routing failed. Use the call buttons."; return }
        #endif
        if let buffer = buildSirenPCMBuffer() {
            playerNode.scheduleBuffer(buffer, at: nil, options: .loops)
            playerNode.play()
        }
    }

    public func deactivateBystanderSiren() {
        isSirenActive = false
        cancelSpeech()
        guard playbackEnabled else { return }
        playerNode.stop()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(.none)
        #endif
    }

    public func startRASMetronome(bpm: Int = 100) {
        guard !isSirenActive, !isMetronomeActive else { return }
        isMetronomeActive = true
        metronomeBPM = bpm
        // Preempt lower-priority speech even when the cue prompt is cooling down.
        if let active = prompts.active, active.priority > 1 { cancelSpeech() }
        playMetronome()
        guard isAudioAvailable else { return }
        speak("Step to the beat", priority: 1, cue: true)
    }

    private func playMetronome() {
        guard ensureEngineRunning(), playbackEnabled else { return }
        playerNode.stop()
        if let buffer = buildMetronomeClickPCMBuffer(bpm: metronomeBPM) {
            playerNode.scheduleBuffer(buffer, at: nil, options: .loops)
            playerNode.play()
        }
    }

    public func stopRASMetronome() {
        let wasMetronome = isMetronomeActive
        isMetronomeActive = false
        cancelCueSpeech()
        // A stale FoG stop must never silence a subsequently activated siren.
        if wasMetronome && !isSirenActive && playbackEnabled { playerNode.stop() }
    }

    public func playAudioTest() {
        guard !isSirenActive, !isMetronomeActive else { return }
        retryAudio()
        guard isAudioAvailable else { return }
        if playbackEnabled, let buffer = buildMetronomeClickPCMBuffer(bpm: 100) {
            playerNode.stop()
            playerNode.scheduleBuffer(buffer, at: nil, options: [])
            playerNode.play()
        }
        speakPrompt("Cadence audio test. Check that you can hear this.", priority: 2)
    }

    public func speakPrompt(_ text: String, priority: Int = 2) {
        if priority == 0 { stopRASMetronome() }
        speak(text, priority: priority)
    }

    private func speak(_ text: String, priority: Int, cue: Bool = false, voiceID: String? = nil) {
        if isSirenActive && priority > 0 { return }
        if isMetronomeActive && priority > 1 { return }
        guard !isInterrupted, !awaitingExplicitResume,
              let prompt = prompts.request(text, priority: priority, now: ProcessInfo.processInfo.systemUptime, cue: cue) else { return }
        guard playbackEnabled else { return }
        // Never enqueue behind an old prompt, even at equal priority.
        synthesizer.stopSpeaking(at: .immediate)
        utteranceIDs.removeAll()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voiceID.flatMap(AVSpeechSynthesisVoice.init(identifier:)) ?? currentVoice()
        utterance.rate = 0.48
        utterance.pitchMultiplier = 1.0
        utterance.volume = priority == 0 ? 1.0 : 0.85
        utteranceIDs[ObjectIdentifier(utterance)] = prompt.id
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
        guard !isSirenActive, !isMetronomeActive else { return }
        speak("Hello. This is how Cadence will sound. Step with the beat.", priority: 2, voiceID: voiceIdentifier)
    }

    fileprivate func speechFinished(_ utterance: AVSpeechUtterance) {
        guard let id = utteranceIDs.removeValue(forKey: ObjectIdentifier(utterance)) else { return }
        prompts.finished(id)
        speechDidEnd()
    }

    // MARK: - Echo window

    public func isInEchoWindow(at date: Date) -> Bool {
        echoLock.lock(); defer { echoLock.unlock() }
        return (playbackEnabled && synthesizer.isSpeaking) || echoWindow.isActive(at: date)
    }

    fileprivate func speechDidStart(_ utterance: AVSpeechUtterance) {
        guard let id = utteranceIDs[ObjectIdentifier(utterance)], prompts.active?.id == id else { return }
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
        engine.speechDidStart(utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        engine.speechFinished(utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        engine.speechFinished(utterance)
    }
}

/// State-only keepalive selected exclusively by the explicit unit-test flag.
private final class TestKeepAlive: BackgroundKeepAliving {
    private(set) var isActive = false
    func start() { isActive = true }
    func stop() { isActive = false }
}
