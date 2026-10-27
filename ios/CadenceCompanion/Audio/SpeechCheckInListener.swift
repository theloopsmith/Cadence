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
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onEarlyResolution = onEarlyResolution
    }

    public func simulateUtterance(_ text: String, peakDbfs: Double = -20.0) {
        latestTranscript = text
        maxVocalLevelDbfs = max(maxVocalLevelDbfs, peakDbfs)
        onTranscriptUpdate?(text, maxVocalLevelDbfs)

        let normalized = text.lowercased()
        for kw in FallDetector.distressAndNegationKeywords {
            if normalized.contains(kw) {
                onEarlyResolution?("confirmed_waiting_dispatch")
                return
            }
        }
        for phrase in FallDetector.affirmativeCancelPhrases {
            if normalized.contains(phrase) {
                onEarlyResolution?("canceled_false_alarm")
                return
            }
        }
    }

    public func stopListening() -> (transcript: String, maxDbfs: Double) {
        isListening = false
        return (latestTranscript, maxVocalLevelDbfs)
    }
}

public final class LiveSpeechCheckInListener: NSObject, SpeechCheckInListenerProtocol, SFSpeechRecognizerDelegate {
    public static let shared = LiveSpeechCheckInListener()

    private let recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    public private(set) var maxVocalLevelDbfs: Double = -100.0
    public private(set) var latestTranscript: String = ""
    public private(set) var isListening: Bool = false

    private var transcriptCallback: ((String, Double) -> Void)?
    private var earlyResolutionCallback: ((String) -> Void)?

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
        self.isListening = true
        self.maxVocalLevelDbfs = -100.0
        self.latestTranscript = ""
        self.transcriptCallback = onTranscriptUpdate
        self.earlyResolutionCallback = onEarlyResolution

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

            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
                guard let self = self else { return }
                request.append(buffer)

                // Compute buffer RMS amplitude for vocal level & groan tracking
                if let channelData = buffer.floatChannelData?[0] {
                    let frameLength = Int(buffer.frameLength)
                    var sumSquares: Float = 0.0
                    for i in 0..<frameLength {
                        let sample = channelData[i]
                        sumSquares += sample * sample
                    }
                    let rms = sqrt(sumSquares / Float(max(1, frameLength)))
                    let dbfs = Double(20.0 * log10(max(1e-5, rms)))
                    DispatchQueue.main.async {
                        self.maxVocalLevelDbfs = max(self.maxVocalLevelDbfs, dbfs)
                    }
                }
            }

            audioEngine.prepare()
            try audioEngine.start()

            self.recognitionTask = recognizer?.recognitionTask(with: request) { [weak self] result, error in
                guard let self = self else { return }
                if let result = result {
                    let text = result.bestTranscription.formattedString
                    DispatchQueue.main.async {
                        self.latestTranscript = text
                        self.transcriptCallback?(text, self.maxVocalLevelDbfs)
                        self.evaluateEarlyPhrases(text)
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

    private func evaluateEarlyPhrases(_ transcript: String) {
        let normalized = transcript.lowercased()

        // 1. Distress keyword -> Immediate escalation
        for kw in FallDetector.distressAndNegationKeywords {
            if normalized.contains(kw) {
                earlyResolutionCallback?("confirmed_waiting_dispatch")
                return
            }
        }

        // 2. Multi-word affirmative cancel phrase -> Immediate cancel
        for phrase in FallDetector.affirmativeCancelPhrases {
            if normalized.contains(phrase) {
                earlyResolutionCallback?("canceled_false_alarm")
                return
            }
        }
    }

    @discardableResult
    public func stopListening() -> (transcript: String, maxDbfs: Double) {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil

        isListening = false
        return (latestTranscript, maxVocalLevelDbfs)
    }
}
