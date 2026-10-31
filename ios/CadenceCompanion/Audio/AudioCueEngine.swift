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
    private var inputOwnership = AudioInputOwnership()
    private var configurationRecoveryID = UUID()
    private var configurationRecoveryPending = false
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
            if !self.engine.isRunning { self.outputConfigurationChanged() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] notification in
            AudioRouteManager.shared.updateCurrentInput()
            let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            if AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable {
                let previous = notification.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription
                let oldNames = Set(previous?.outputs.map(\.portName) ?? [])
                let newNames = Set(AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portName))
                // HFP and A2DP can have different port identifiers for the same
                // glasses. An input/profile switch is not an unplugged output.
                if oldNames.isEmpty || oldNames.isDisjoint(with: newNames) {
                    self?.outputDeviceDisconnected()
                }
            }
        })
        #endif
    }

    /// Bluetooth profile/rate changes stop AVAudioEngine while iOS negotiates
    /// its route. Coalesce the notifications and give that route time to settle.
    /// Explicit pauses (including actual output removal) always win.
    func outputConfigurationChanged(attempt: Int = 0) {
        guard !awaitingExplicitResume, !isInterrupted else { return }
        let id = UUID()
        configurationRecoveryID = id
        configurationRecoveryPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.configurationRecoveryID == id,
                  !self.awaitingExplicitResume, !self.isInterrupted else { return }
            self.configurationRecoveryPending = false
            guard self.isSirenActive || self.isMetronomeActive ||
                    (self.keepAlive as? SilentAudioKeepAlive)?.isRequested == true else { return }
            if self.ensureEngineRunning() {
                if self.isSirenActive { self.playSiren() }
                else if self.isMetronomeActive { self.playMetronome() }
                (self.keepAlive as? SilentAudioKeepAlive)?.resumeIfRequested()
            } else if attempt < 2 {
                self.outputConfigurationChanged(attempt: attempt + 1)
            } else {
                self.pauseOutput(reason: "Audio could not recover after the route changed. Reopen Cadence to retry, or check audio in Settings.")
            }
        }
    }

    private func pauseOutput(reason: String) {
        configurationRecoveryID = UUID()
        configurationRecoveryPending = false
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
        // An emergency siren resumes unconditionally: the wearer is on the
        // floor and the interruption was most likely the caregiver calling back.
        if isSirenActive { resetRequiresUserAction = false; retryAudio(); return }
        if shouldResume && resumeAfterInterruption && !resetRequiresUserAction { retryAudio() }
        else { audioProblem = "Audio paused. Tap Retry audio when ready." }
    }

    func mediaServicesReset() {
        resetRequiresUserAction = true
        mediaServicesGeneration += 1
        pauseOutput(reason: "Audio services restarted. Tap Retry audio when ready.")
        // No automatic playback after a media-services reset, except the
        // siren, which comes back by itself once the system has settled.
        if isSirenActive {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, self.isSirenActive else { return }
                self.resetRequiresUserAction = false
                self.retryAudio()
            }
        }
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
    public func configureLaunchAudioSession(preferVoiceChat: Bool = false, requiresInput: Bool = false) -> Bool {
        guard !isInterrupted, !awaitingExplicitResume else { return false }
        guard playbackEnabled else { sessionConfigured = true; return true }
        sessionConfigured = false
        let requiresInput = requiresInput || inputOwnership.requiresInput || isSirenActive
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
            if requiresInput {
                let options: AVAudioSession.CategoryOptions = isSirenActive ? [.defaultToSpeaker] : [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP]
                let mode: AVAudioSession.Mode = preferVoiceChat ? .voiceChat : .default
                if session.category != .playAndRecord || session.mode != mode || session.categoryOptions != options {
                    try session.setCategory(.playAndRecord, mode: mode, options: options)
                }
                try session.setActive(true)
                if !isSirenActive { AudioRouteManager.shared.routeToGlassesIfAvailable() }
            } else {
                if session.preferredInput != nil { try? session.setPreferredInput(nil) }
                if session.category != .playback || session.mode != .default || session.categoryOptions != [.mixWithOthers] {
                    try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
                }
                try session.setActive(true)
            }
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
    func prepareMicrophoneSession(owner: AudioInputOwner = .transcript) -> Bool {
        if !Thread.isMainThread { return DispatchQueue.main.sync { self.prepareMicrophoneSession(owner: owner) } }
        inputOwnership.acquire(owner)
        guard configureLaunchAudioSession(requiresInput: true) else { inputOwnership.release(owner); return false }
        return true
    }

    func releaseMicrophoneSession(owner: AudioInputOwner) {
        if !Thread.isMainThread { DispatchQueue.main.sync { self.releaseMicrophoneSession(owner: owner) }; return }
        inputOwnership.release(owner)
        if !inputOwnership.requiresInput, !isSirenActive { _ = configureLaunchAudioSession() }
    }

    /// Intentional handoff: release the Bluetooth call route as well as the tap.
    public func releaseForMetaAssistant() throws {
        guard !isSirenActive else { return }
        pauseOutput(reason: "Cadence audio is paused so you can use Hey Meta. Say Siri, open Cadence to return.")
        #if os(iOS)
        if playbackEnabled {
            let session = AVAudioSession.sharedInstance()
            try? session.setPreferredInput(nil)
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(false, options: [.notifyOthersOnDeactivation])
        }
        #endif
        AudioRouteManager.shared.updateCurrentInput()
    }

    func currentMediaServicesGeneration() -> Int {
        if Thread.isMainThread { return mediaServicesGeneration }
        return DispatchQueue.main.sync { self.mediaServicesGeneration }
    }

    public func checkOutputHealth() {
        if playbackEnabled && !isInterrupted && !awaitingExplicitResume && !configurationRecoveryPending &&
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
        guard configureLaunchAudioSession(requiresInput: true), ensureEngineRunning(), playbackEnabled else { return }
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
        _ = configureLaunchAudioSession()
    }

    /// True while a fall check-in is listening. Walking cues must not start
    /// then: the click would reach the check-in microphone as a "voice".
    public var checkInActive = false

    public func startRASMetronome(bpm: Int = 100) {
        guard !isSirenActive, !isMetronomeActive, !checkInActive else { return }
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

    public func refreshVoiceSelection() { cachedVoice = nil }

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
        // Anything the phone plays can come back through its own microphone.
        return (playbackEnabled && synthesizer.isSpeaking) || isMetronomeActive || isSirenActive
            || echoWindow.isActive(at: date)
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
