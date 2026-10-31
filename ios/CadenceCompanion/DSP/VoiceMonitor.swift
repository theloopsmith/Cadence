import AVFoundation
import Foundation

/// Tracks 100ms sliding RMS voice volume (dBFS) and computes 5-second vowel-only
/// phonation amplitude stability (sigma_dB,phonation) for Task 1 of the Guided Home Motor Exam.
public final class VoiceMonitor {
    public static let shared = VoiceMonitor()

    public private(set) var currentLevelDbfs: Double = -50.0
    public var isUserSpeaking: Bool {
        return currentLevelDbfs > -38.0
    }

    private var audioEngine = AVAudioEngine()
    private var audioGeneration = 0
    private var pauseObserver: NSObjectProtocol?
    public private(set) var isMonitoring: Bool = false
    private var isRecordingVowel: Bool = false
    private var recordedVowelSamples: [Double] = []
    public private(set) var lastVowelSampleCount = 0
    private var hasInstalledTap: Bool = false

    public init() {
        pauseObserver = NotificationCenter.default.addObserver(forName: .cadenceAudioPaused, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.stopLiveMonitoring()
            self.isRecordingVowel = false
            self.recordedVowelSamples.removeAll()
        }
    }

    deinit { if let pauseObserver { NotificationCenter.default.removeObserver(pauseObserver) } }

    /// Manual level update (used by mock streams, simulator replayers, or tests)
    public func updateSampleLevel(dbfs: Double) {
        self.currentLevelDbfs = dbfs
        if isRecordingVowel {
            recordedVowelSamples.append(dbfs)
        }
    }

    /// Starts live audio input monitoring via AVAudioEngine inputNode
    public func startLiveMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true

        guard AudioCueEngine.shared.prepareMicrophoneSession(owner: .motorVoice) else {
            isMonitoring = false
            return
        }
        let generation = AudioCueEngine.shared.currentMediaServicesGeneration()
        if generation != audioGeneration {
            // Audio objects from before a media-services reset are invalid.
            audioEngine = AVAudioEngine()
            hasInstalledTap = false
            audioGeneration = generation
        }


        do {
            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)

            guard recordingFormat.sampleRate > 0 && recordingFormat.channelCount > 0 else {
                stopLiveMonitoring()
                return
            }

            if hasInstalledTap {
                inputNode.removeTap(onBus: 0)
                hasInstalledTap = false
            }

            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
                guard let self = self, let channelData = buffer.floatChannelData?[0] else { return }
                let frameLength = Int(buffer.frameLength)
                var sumSquares: Float = 0.0
                for i in 0..<frameLength {
                    let sample = channelData[i]
                    sumSquares += sample * sample
                }
                let rms = sqrt(sumSquares / Float(max(1, frameLength)))
                let dbfs = Double(20.0 * log10(max(1e-5, rms)))
                DispatchQueue.main.async {
                    self.updateSampleLevel(dbfs: dbfs)
                }
            }
            hasInstalledTap = true

            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            print("VoiceMonitor live monitoring error: \(error)")
            stopLiveMonitoring()
        }
    }

    public func stopLiveMonitoring() {
        let generation = AudioCueEngine.shared.currentMediaServicesGeneration()
        if generation != audioGeneration {
            audioEngine = AVAudioEngine()
            hasInstalledTap = false
            audioGeneration = generation
        }
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if hasInstalledTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasInstalledTap = false
        }
        isMonitoring = false
        // The last loud sample must not latch "speaking" for the rest of the
        // session; that would quietly raise the freeze threshold.
        currentLevelDbfs = -50.0
        AudioCueEngine.shared.releaseMicrophoneSession(owner: .motorVoice)
    }

    /// Begins recording 100ms RMS samples for the 5-second sustained vowel ("Ahhh") task.
    public func startVowelPhonationRecording() {
        isRecordingVowel = true
        recordedVowelSamples.removeAll()
        lastVowelSampleCount = 0
    }

    /// Finishes recording and returns (meanDbfs, stabilityDb)
    public func stopVowelPhonationRecording() -> (meanDbfs: Double, stabilityDb: Double) {
        isRecordingVowel = false
        lastVowelSampleCount = recordedVowelSamples.count
        guard !recordedVowelSamples.isEmpty else {
            return (currentLevelDbfs, 0.0)
        }
        let mean = recordedVowelSamples.reduce(0.0, +) / Double(recordedVowelSamples.count)
        let stability = computeVowelPhonationStabilityDb(vowelWindowDbfsSamples: recordedVowelSamples)
        return (mean, stability)
    }

    /// Computes phonation stability sigma_dB strictly over the 5-second sustained vowel ("Ahhh") segment.
    public func computeVowelPhonationStabilityDb(vowelWindowDbfsSamples: [Double]) -> Double {
        guard vowelWindowDbfsSamples.count >= 2 else { return 0.0 }
        let mean = vowelWindowDbfsSamples.reduce(0.0, +) / Double(vowelWindowDbfsSamples.count)
        let variance = vowelWindowDbfsSamples.reduce(0.0) { acc, val in
            let diff = val - mean
            return acc + diff * diff
        } / Double(vowelWindowDbfsSamples.count)
        return sqrt(variance)
    }
}
