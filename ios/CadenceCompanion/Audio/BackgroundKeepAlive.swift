import AVFoundation
import Foundation

/// Keeps the process running while protection streams motion with the
/// screen locked.
///
/// iOS suspends a backgrounded app within about thirty seconds unless an
/// audio session is actively playing. With `UIBackgroundModes: audio` and a
/// looping silent buffer, CoreMotion and the detectors keep running with the
/// phone in a pocket. The buffer is silence, so it is inaudible and does
/// not interfere with cues, prompts, or the siren, which play on their own
/// node of the same engine.
public protocol BackgroundKeepAliving: AnyObject {
    var isActive: Bool { get }
    func start()
    func stop()
}

public final class SilentAudioKeepAlive: BackgroundKeepAliving {
    public private(set) var isActive = false
    private let engine: AVAudioEngine
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44100.0, channels: 1)!
    private var attached = false

    /// Shares the cue engine's `AVAudioEngine` so one session is active.
    public init(engine: AVAudioEngine) {
        self.engine = engine
    }

    public func start() {
        guard !isActive else { return }
        if !attached {
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            attached = true
        }
        if !engine.isRunning {
            try? engine.start()
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate)) else {
            return
        }
        buffer.frameLength = buffer.frameCapacity
        if let channel = buffer.floatChannelData?[0] {
            for i in 0..<Int(buffer.frameLength) { channel[i] = 0 }
        }
        node.volume = 0
        node.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
        node.play()
        isActive = true
    }

    public func stop() {
        guard isActive else { return }
        node.stop()
        isActive = false
    }
}
