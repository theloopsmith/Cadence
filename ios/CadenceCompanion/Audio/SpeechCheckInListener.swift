import AVFoundation
import Foundation
import Speech

public protocol SpeechCheckInListenerProtocol: AnyObject {
    var maxVocalLevelDbfs: Double { get }
    var latestTranscript: String { get }
    var isListening: Bool { get }

    func startListening(
        onTranscriptUpdate: @escaping (String, Double) -> Void,
        onEarlyResolution: @escaping (String) -> Void
    )
    func stopListening() -> (transcript: String, maxDbfs: Double)
}

public final class MockSpeechCheckInListener: SpeechCheckInListenerProtocol {
    public var maxVocalLevelDbfs: Double = -100.0
    public var latestTranscript: String = ""
    public var isListening: Bool = false

    private var evidence = DualRecognizerCheckIn()

    public var onTranscriptUpdate: ((String, Double) -> Void)?
    public var onEarlyResolution: ((String) -> Void)?

    public init(maxDbfs: Double = -100.0, transcript: String = "") {
        self.maxVocalLevelDbfs = maxDbfs
        self.latestTranscript = transcript
    }

    public func startListening(
        onTranscriptUpdate: @escaping (String, Double) -> Void,
        onEarlyResolution: @escaping (String) -> Void
    ) {
        self.isListening = true
        evidence = DualRecognizerCheckIn()
        evidence.record(latestTranscript, from: .local)
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onEarlyResolution = onEarlyResolution
    }

    public func simulateUtterance(_ text: String, peakDbfs: Double = -20, source: CheckInRecognizer = .local) {
        guard isListening else { return }
        if source == .local { latestTranscript = text }
        evidence.record(text, from: source)
        maxVocalLevelDbfs = max(maxVocalLevelDbfs,peakDbfs)
        onTranscriptUpdate?(text,maxVocalLevelDbfs)
        if evidence.distressHeard { onEarlyResolution?("confirmed_waiting_dispatch") }
    }

    public func stopListening() -> (transcript: String, maxDbfs: Double) {
        isListening = false
        return (evidence.transcriptForResolution, maxVocalLevelDbfs)
    }
}

public final class LiveSpeechCheckInListener: NSObject, SpeechCheckInListenerProtocol, SFSpeechRecognizerDelegate, @unchecked Sendable {
    public static let shared = LiveSpeechCheckInListener()

    private let recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private var hasInstalledTap: Bool = false
    /// Opening `AVAudioEngine.inputNode` can block. Hardware setup runs here so
    /// `startListening` returns and the 12-second check-in timer stays armed.
    private let audioQueue = DispatchQueue(label: "com.cadence.speechcheckin")
    /// Bumped on start and stop. A setup block that loses the race with stop
    /// sees a newer value and does not open the microphone.
    private var session = 0

    public private(set) var maxVocalLevelDbfs: Double = -100.0
    public private(set) var latestTranscript: String = ""
    public private(set) var isListening: Bool = false

    private var transcriptCallback: ((String, Double) -> Void)?
    private var earlyResolutionCallback: ((String) -> Void)?

    /// Says when the app itself is talking. Nothing heard then counts, so the
    /// spoken prompt can never answer the check-in.
    public var echoGuard: EchoGuarding = AudioCueEngine.shared
    private var echoFilter = EchoFilteredTranscript()

    /// Builds the Muse Voice Transcribe listener that runs beside the
    /// on-device recognizer. Nil (the default) means on-device only.
    public var cloudEarFactory: ((@escaping (String) -> Void) -> CloudEar)?
    private var cloudEar: CloudEar?
    private var evidence = DualRecognizerCheckIn()

    public override init() {
        self.recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        super.init()
        self.recognizer?.delegate = self
    }

    public func requestSpeechAuthorization(completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                completion(status == .authorized)
            }
        }
    }

    public func startListening(
        onTranscriptUpdate: @escaping (String, Double) -> Void,
        onEarlyResolution: @escaping (String) -> Void
    ) {
        guard !isListening else { return }
        session += 1
        let session = session
        self.isListening = true
        self.maxVocalLevelDbfs = -100.0
        self.latestTranscript = ""
        self.transcriptCallback = onTranscriptUpdate
        self.earlyResolutionCallback = onEarlyResolution
        self.echoFilter = EchoFilteredTranscript()
        self.evidence = DualRecognizerCheckIn()
        self.cloudEar = cloudEarFactory? { [weak self] text in
            // Either listener can resolve the check-in; the same rules apply.
            guard let self, self.isListening, self.session == session else { return }
            self.acceptTranscript(text, source: .cloud)
        }
        audioQueue.async { [weak self] in
            self?.openMicrophone(session: session)
        }
    }

    private func openMicrophone(session: Int) {
        guard session == self.session else { return }

        #if os(iOS)
        let audioSession = AVAudioSession.sharedInstance()
        #if targetEnvironment(simulator)
        guard audioSession.isInputAvailable else {
            print("[SpeechCheckInListener] No audio input hardware available on simulator.")
            return
        }
        do {
            try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            print("[SpeechCheckInListener] Could not configure audio session: \(error)")
            return
        }
        #else
        do {
            var options: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
            #if swift(>=5.9)
            options.insert(.allowBluetoothHFP)
            #endif
            try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: options)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            AudioRouteManager.shared.routeToGlassesIfAvailable()
        } catch {
            do {
                try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
                try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
                AudioRouteManager.shared.routeToGlassesIfAvailable()
            } catch {
                print("[SpeechCheckInListener] Audio session recording setup failed: \(error)")
                return
            }
        }
        #endif
        #endif

        do {
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            // Enforce on-device recognition if available for offline safety
            if #available(iOS 13, macOS 10.15, *), recognizer?.supportsOnDeviceRecognition == true {
                request.requiresOnDeviceRecognition = true
            }
            self.recognitionRequest = request

            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)

            guard recordingFormat.sampleRate > 0 && recordingFormat.channelCount > 0 else {
                print("[SpeechCheckInListener] Input node has invalid format (sampleRate=\(recordingFormat.sampleRate), channels=\(recordingFormat.channelCount)). Skipping tap.")
                return
            }

            if hasInstalledTap {
                inputNode.removeTap(onBus: 0)
                hasInstalledTap = false
            }

            let sampleRate = recordingFormat.sampleRate
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
                guard let self = self else { return }
                request.append(buffer)
                let echo = self.echoGuard.isInEchoWindow(at: Date())

                if let channelData = buffer.floatChannelData?[0] {
                    let frameLength = Int(buffer.frameLength)
                    let samples = Array(UnsafeBufferPointer(start: channelData, count: frameLength))
                    self.cloudEar?.feed(samples: samples, sampleRate: sampleRate, echoActive: echo)

                    // Voice level for the groan rule. The app's own prompt is
                    // loud and must not count as the wearer making a sound.
                    guard !echo else { return }
                    var sumSquares: Float = 0.0
                    for sample in samples { sumSquares += sample * sample }
                    let rms = sqrt(sumSquares / Float(max(1, frameLength)))
                    let dbfs = Double(20.0 * log10(max(1e-5, rms)))
                    DispatchQueue.main.async {
                        self.maxVocalLevelDbfs = max(self.maxVocalLevelDbfs, dbfs)
                    }
                }
            }
            hasInstalledTap = true

            audioEngine.prepare()
            try audioEngine.start()

            self.recognitionTask = recognizer?.recognitionTask(with: request) { [weak self] result, error in
                guard let self = self else { return }
                if let result = result {
                    let text = result.bestTranscription.formattedString
                    let echo = self.echoGuard.isInEchoWindow(at: Date())
                    DispatchQueue.main.async {
                        guard self.isListening, self.session == session else { return }
                        guard let fresh = self.echoFilter.update(fullTranscript: text, echoActive: echo) else { return }
                        self.latestTranscript = fresh
                        self.transcriptCallback?(fresh, self.maxVocalLevelDbfs)
                        self.acceptTranscript(fresh, source: .local)
                    }
                }
                if error != nil || (result?.isFinal ?? false) {
                    // Task completed or stopped
                }
            }
        } catch {
            print("SpeechCheckInListener start error: \(error)")
            isListening = false
        }
    }

    private func acceptTranscript(_ text: String, source: CheckInRecognizer) {
        evidence.record(text, from: source)
        if evidence.distressHeard { earlyResolutionCallback?("confirmed_waiting_dispatch") }
    }

    @discardableResult
    public func stopListening() -> (transcript: String, maxDbfs: Double) {
        session += 1
        let result = (evidence.transcriptForResolution, maxVocalLevelDbfs)
        isListening = false
        cloudEar?.stop()
        cloudEar = nil
        audioQueue.async { [weak self] in
            self?.tearDownEngine()
        }
        return result
    }

    private func tearDownEngine() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if hasInstalledTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasInstalledTap = false
        }
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
    }
}
