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

    private let audioEngine = AVAudioEngine()
    public private(set) var isMonitoring: Bool = false
    private var isRecordingVowel: Bool = false
    private var recordedVowelSamples: [Double] = []

    public init() {}

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

        do {
            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)

            inputNode.removeTap(onBus: 0)
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

            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            print("VoiceMonitor live monitoring error: \(error)")
            isMonitoring = false
        }
    }

    public func stopLiveMonitoring() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        isMonitoring = false
    }

    /// Begins recording 100ms RMS samples for the 5-second sustained vowel ("Ahhh") task.
    public func startVowelPhonationRecording() {
        isRecordingVowel = true
        recordedVowelSamples.removeAll()
    }

    /// Finishes recording and returns (meanDbfs, stabilityDb)
    public func stopVowelPhonationRecording() -> (meanDbfs: Double, stabilityDb: Double) {
        isRecordingVowel = false
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
