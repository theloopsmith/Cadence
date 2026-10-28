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
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer?.supportsOnDeviceRecognition == true {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
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
                self.audioEngine.inputNode.removeTap(onBus: 0)
            }
            self.request?.endAudio()
            self.request = nil
            self.task?.cancel()
            self.task = nil
        }
    }
}
