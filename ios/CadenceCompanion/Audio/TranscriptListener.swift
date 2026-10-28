import AVFoundation
import Foundation
import Speech

/// Streams partial transcripts from the microphone. Separate from the fall
/// check-in listener, whose phrase rules are specific to a fall.
public protocol TranscriptListening: AnyObject {
    var isListening: Bool { get }
    func startListening(onTranscript: @escaping (String) -> Void)
    func stopListening()
}

/// Says something to the wearer. The app's speaker is `AudioCueEngine`.
public protocol PromptSpeaking: AnyObject {
    func speak(_ text: String)
}

extension AudioCueEngine: PromptSpeaking {
    public func speak(_ text: String) {
        speakPrompt(text, priority: 2)
    }
}

/// On-device `SFSpeechRecognizer` transcription for everyday voice input.
public final class LiveTranscriptListener: NSObject, TranscriptListening, @unchecked Sendable {
    public static let shared = LiveTranscriptListener()

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private let audioQueue = DispatchQueue(label: "com.cadence.transcript")
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var session = 0
    private var hasInstalledTap: Bool = false
    public private(set) var isListening = false

    public func startListening(onTranscript: @escaping (String) -> Void) {
        guard !isListening else { return }
        isListening = true
        session += 1
        let session = session
        audioQueue.async { [weak self] in
            self?.open(session: session, onTranscript: onTranscript)
        }
    }

    private func open(session: Int, onTranscript: @escaping (String) -> Void) {
        guard session == self.session else { return }

        #if os(iOS)
        let audioSession = AVAudioSession.sharedInstance()
        #if targetEnvironment(simulator)
        guard audioSession.isInputAvailable else {
            print("[TranscriptListener] No audio input available on simulator.")
            isListening = false
            return
        }
        do {
            try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            print("[TranscriptListener] Audio session error: \(error)")
            isListening = false
            return
        }
        #else
        do {
            try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            do {
                try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
                try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            } catch {
                isListening = false
                return
            }
        }
        #endif
        #endif

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer?.supportsOnDeviceRecognition == true {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 && format.channelCount > 0 else {
            print("[TranscriptListener] Invalid input format: \(format)")
            isListening = false
            return
        }

        if hasInstalledTap {
            input.removeTap(onBus: 0)
            hasInstalledTap = false
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        hasInstalledTap = true

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            isListening = false
            return
        }
        task = recognizer?.recognitionTask(with: request) { result, _ in
            guard let result else { return }
            let text = result.bestTranscription.formattedString
            DispatchQueue.main.async { onTranscript(text) }
        }
    }

    public func stopListening() {
        session += 1
        isListening = false
        audioQueue.async { [weak self] in
            guard let self else { return }
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
        }
    }
}
