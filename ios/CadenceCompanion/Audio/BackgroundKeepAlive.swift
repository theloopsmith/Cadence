import AVFoundation
import Foundation

/// Requests background audio while motion runs. This is not a guarantee that
/// iOS will keep the process or sensors alive; sample freshness is checked separately.
public protocol BackgroundKeepAliving: AnyObject {
    var isActive: Bool { get }
    var failureReason: String? { get }
    func start()
    func stop()
}
public extension BackgroundKeepAliving { var failureReason: String? { nil } }

public final class SilentAudioKeepAlive: BackgroundKeepAliving {
    public var isActive: Bool { scheduled && engine.isRunning && node.isPlaying }
    public private(set) var failureReason: String?
    private var scheduled = false
    private var requested = false
    var isRequested: Bool { requested }
    private var engine: AVAudioEngine
    private var node = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44100.0, channels: 1)!
    private var attached = false

    /// Shares the cue engine's `AVAudioEngine` so one session is active.
    public init(engine: AVAudioEngine) {
        self.engine = engine
    }

    public func start() {
        requested = true
        guard !isActive else { return }
        if !attached {
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            attached = true
        }
        if !engine.isRunning {
            do { try engine.start() }
            catch { failureReason = "Background audio could not start."; return }
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate)) else {
            failureReason = "Background audio could not be prepared."
            return
        }
        buffer.frameLength = buffer.frameCapacity
        if let channel = buffer.floatChannelData?[0] {
            for i in 0..<Int(buffer.frameLength) { channel[i] = 0 }
        }
        node.volume = 0
        node.stop()
        node.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
        node.play()
        scheduled = true
        failureReason = isActive ? nil : "Background audio is unavailable."
    }

    public func stop() {
        requested = false
        suspend()
        failureReason = nil
    }

    func suspend() {
        node.stop()
        scheduled = false
    }

    func resumeIfRequested() { if requested { start() } }

    /// Media services invalidates the old engine and nodes. Keep this wrapper
    /// stable because WalkingModel holds it, while replacing its hardware objects.
    func rebuild(using engine: AVAudioEngine) {
        suspend()
        self.engine = engine
        node = AVAudioPlayerNode()
        attached = false
    }
}
