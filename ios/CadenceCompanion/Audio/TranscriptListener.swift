import AVFoundation
import Foundation
import Speech

/// Streams partial transcripts from the microphone. Separate from the fall
/// check-in listener, whose phrase rules are specific to a fall.
public protocol TranscriptListening: AnyObject {
    var isListening: Bool { get }
    var isReady: Bool { get }
    var failureReason: String? { get }
    func startListening(onTranscript: @escaping (String) -> Void)
    func stopListening()
    func waitUntilStopped() async
    var waitsForMicrophoneReleaseBeforeSpeech: Bool { get }
}

public extension TranscriptListening {
    var isReady: Bool { isListening }
    var failureReason: String? { nil }
    func waitUntilStopped() async {}
    var waitsForMicrophoneReleaseBeforeSpeech: Bool { false }
}

/// Says something to the wearer. The app's speaker is `AudioCueEngine`.
public protocol PromptSpeaking: AnyObject {
    /// Returns false when the text could not be spoken right now (for example
    /// walking cues or the siren own the speaker), so the caller can say so.
    @discardableResult
    func speak(_ text: String) -> Bool
    func cancel()
}

public extension PromptSpeaking { func cancel() {} }

extension AudioCueEngine: PromptSpeaking {
    public func cancel() { cancelNonEmergencySpeech() }
    @discardableResult
    public func speak(_ text: String) -> Bool {
        guard !isMetronomeActive, !isSirenActive else { return false }
        speakPrompt(text, priority: 2)
        return true
    }
}

/// On-device `SFSpeechRecognizer` transcription for everyday voice input.
public final class LiveTranscriptListener: NSObject, TranscriptListening, @unchecked Sendable {
    public static let shared = LiveTranscriptListener()
    public var waitsForMicrophoneReleaseBeforeSpeech: Bool { true }

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var audioEngine = AVAudioEngine()
    private var audioGeneration = 0
    private var pauseObserver: NSObjectProtocol?
    private var configurationObserver: NSObjectProtocol?
    private var transcriptCallback: ((String) -> Void)?
    private let audioQueue = DispatchQueue(label: "com.cadence.transcript")
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var session = 0
    private var hasInstalledTap: Bool = false
    private var inputHasStarted = false
    public private(set) var isListening = false
    public var isReady: Bool { isListening && inputHasStarted }
    public private(set) var failureReason: String?

    /// Nothing heard while the app is speaking counts, so a spoken prompt can
    /// never answer itself.
    public var echoGuard: EchoGuarding = AudioCueEngine.shared
    private var echoFilter = EchoFilteredTranscript()

    /// Builds the Muse Voice Transcribe listener beside the on-device one.
    public var cloudEarFactory: ((@escaping (String) -> Void) -> CloudEar)?
    private var cloudEar: CloudEar?

    public override init() {
        super.init()
        pauseObserver = NotificationCenter.default.addObserver(forName: .cadenceAudioPaused, object: nil, queue: .main) { [weak self] _ in self?.stopListening() }
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] notification in
            guard let self, let changed = notification.object as? AVAudioEngine,
                  changed === self.audioEngine, !changed.isRunning, self.isListening, self.inputHasStarted else { return }
            let session = self.session
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, self.session == session, self.isListening,
                      !self.audioEngine.isRunning,
                      let callback = self.transcriptCallback else { return }
                self.stopListening()
                self.startListening(onTranscript: callback)
            }
        }
    }

    deinit {
        if let pauseObserver { NotificationCenter.default.removeObserver(pauseObserver) }
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
    }

    public func startListening(onTranscript: @escaping (String) -> Void) {
        guard !isListening else { return }
        isListening = true
        inputHasStarted = false
        failureReason = nil
        transcriptCallback = onTranscript
        session += 1
        let session = session
        echoFilter = EchoFilteredTranscript()
        cloudEar = cloudEarFactory? { [weak self] text in
            guard let self, self.isListening, self.session == session else { return }
            onTranscript(text)
        }
        audioQueue.async { [weak self] in
            self?.open(session: session, onTranscript: onTranscript)
        }
    }

    private func open(session: Int, onTranscript: @escaping (String) -> Void) {
        guard session == self.session else { return }

        guard AudioCueEngine.shared.prepareMicrophoneSession() else {
            fail(session: session, reason: "Audio is paused or unavailable. Reopen Cadence to retry the microphone.")
            return
        }
        guard session == self.session else {
            AudioCueEngine.shared.releaseMicrophoneSession(owner: .transcript)
            return
        }
        // Preferred Bluetooth input can take a moment to negotiate its format.
        audioQueue.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.openSettledMicrophone(session: session, onTranscript: onTranscript)
        }
    }

    private func openSettledMicrophone(session: Int, onTranscript: @escaping (String) -> Void, attempt: Int = 0) {
        guard session == self.session, isListening else { return }
        let generation = AudioCueEngine.shared.currentMediaServicesGeneration()
        if generation != audioGeneration || !hasInstalledTap {
            // Audio objects from before a media-services reset are invalid.
            audioEngine = AVAudioEngine()
            hasInstalledTap = false
            audioGeneration = generation
        }


        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // System on-device speech only; Muse is the only cloud ASR provider.
        request.requiresOnDeviceRecognition = true
        self.request = request
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 && format.channelCount > 0 else {
            print("[TranscriptListener] Invalid input format: \(format)")
            retryMicrophone(session: session, onTranscript: onTranscript, attempt: attempt,
                            reason: "The microphone has no usable audio input. Check that the glasses are connected, or use the iPhone microphone.")
            return
        }

        if hasInstalledTap {
            input.removeTap(onBus: 0)
            hasInstalledTap = false
        }
        let sampleRate = format.sampleRate
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            guard let self, let channel = buffer.floatChannelData?[0] else { return }
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            self.cloudEar?.feed(
                samples: samples, sampleRate: sampleRate,
                echoActive: self.echoGuard.isInEchoWindow(at: Date())
            )
        }
        hasInstalledTap = true

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            retryMicrophone(session: session, onTranscript: onTranscript, attempt: attempt,
                            reason: "The microphone could not start after reconnecting. Close other calls or recording apps, then reopen Cadence.")
            return
        }
        guard self.session == session, isListening else { return }
        inputHasStarted = true
        task = recognizer?.recognitionTask(with: request) { [weak self] result, _ in
            guard let self, let result else { return }
            let text = result.bestTranscription.formattedString
            let echo = self.echoGuard.isInEchoWindow(at: Date())
            DispatchQueue.main.async {
                guard self.isListening, self.session == session else { return }
                guard let fresh = self.echoFilter.update(fullTranscript: text, echoActive: echo) else { return }
                onTranscript(fresh)
            }
        }
    }

    private func retryMicrophone(session: Int, onTranscript: @escaping (String) -> Void, attempt: Int, reason: String) {
        guard self.session == session, isListening else { return }
        let currentGeneration = AudioCueEngine.shared.currentMediaServicesGeneration()
        if currentGeneration != audioGeneration {
            audioEngine = AVAudioEngine()
            hasInstalledTap = false
            audioGeneration = currentGeneration
        } else {
            audioEngine.stop()
            if hasInstalledTap { audioEngine.inputNode.removeTap(onBus: 0); hasInstalledTap = false }
        }
        request?.endAudio(); request = nil
        task?.cancel(); task = nil
        guard attempt < 2 else { fail(session: session, reason: reason); return }
        audioQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.openSettledMicrophone(session: session, onTranscript: onTranscript, attempt: attempt + 1)
        }
    }

    private func fail(session: Int, reason: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.session == session, self.isListening else { return }
            self.stopListening()
            self.failureReason = reason
        }
    }

    public func waitUntilStopped() async {
        await withCheckedContinuation { continuation in
            audioQueue.async { continuation.resume() }
        }
    }

    public func stopListening() {
        session += 1
        isListening = false
        inputHasStarted = false
        transcriptCallback = nil
        cloudEar?.stop()
        cloudEar = nil
        audioQueue.async { [weak self] in
            guard let self else { return }
            let generation = AudioCueEngine.shared.currentMediaServicesGeneration()
            if generation != self.audioGeneration {
                self.audioEngine = AVAudioEngine()
                self.hasInstalledTap = false
                self.audioGeneration = generation
            }
            if self.audioEngine.isRunning {
                self.audioEngine.stop()
            }
            if self.hasInstalledTap {
                self.audioEngine.inputNode.removeTap(onBus: 0)
                self.hasInstalledTap = false
            }
            self.request?.endAudio()
            self.request = nil
            self.task?.cancel()
            self.task = nil
            AudioCueEngine.shared.releaseMicrophoneSession(owner: .transcript)
        }
    }
}
