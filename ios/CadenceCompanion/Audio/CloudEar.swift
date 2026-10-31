import Foundation

/// A second listener next to the on-device recognizer, backed by Muse Voice
/// Transcribe through the Cadence server.
///
/// Microphone audio is downmixed and resampled to 16 kHz mono, and the last
/// few seconds are sent every couple of seconds while someone is speaking.
/// Silence is never sent, audio heard while the app is speaking is dropped,
/// and only one request is in flight at a time. If the server or network is
/// unavailable, the on-device recognizer carries on alone.
public final class CloudEar: @unchecked Sendable {
    public typealias Transcriber = @Sendable (Data) async -> String?

    public static let sampleRate: Double = 16000

    private let windowSamples: Int
    private let strideSamples: Int
    /// Peak amplitude (0…1) a window needs before it is worth sending.
    private let speechThreshold: Float
    private let transcribe: Transcriber
    private let onTranscript: (String) -> Void
    private let deliverQueue: DispatchQueue

    private let lock = NSLock()
    // Only admission and small snapshots use the lock. PCM work stays on the
    // serial worker, and producers never wait for resampling or WAV encoding.
    let processingQueue = DispatchQueue(label: "com.cadence.cloud-ear", qos: .userInitiated)
    private var queuedBuffers = 0
    private var queuedSeconds = 0.0
    private var generation = 0
    private var bufferedDuration = 0.0
    private var bufferGeneration = -1
    private var buffer: [Int16] = []
    private var newSinceSend = 0
    private var inFlight = false
    private var stopped = false

    public init(
        windowSec: Double = 6,
        strideSec: Double = 2.5,
        speechThreshold: Float = 0.02,
        transcribe: @escaping Transcriber,
        onTranscript: @escaping (String) -> Void,
        deliverOn queue: DispatchQueue = .main
    ) {
        self.windowSamples = Int(windowSec * Self.sampleRate)
        self.strideSamples = Int(strideSec * Self.sampleRate)
        self.speechThreshold = speechThreshold
        self.transcribe = transcribe
        self.onTranscript = onTranscript
        self.deliverQueue = queue
    }

    public var bufferedSeconds: Double {
        lock.lock(); defer { lock.unlock() }
        return bufferedDuration
    }

    /// Enqueues a copied mono buffer. Admission is bounded to eight buffers and
    /// six seconds of PCM; overload discards the incomplete utterance rather
    /// than joining speech across a missing segment.
    public func feed(samples: [Float], sampleRate: Double, echoActive: Bool = false) {
        guard sampleRate.isFinite, sampleRate >= 8000, sampleRate <= 192000 else { return }
        let duration = Double(samples.count) / sampleRate
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        if echoActive || queuedBuffers >= 8 || queuedSeconds + duration > 6 {
            generation += 1
            bufferedDuration = 0
            return
        }
        guard !samples.isEmpty else { return }
        let generation = self.generation
        queuedBuffers += 1
        queuedSeconds += duration
        // Submit while holding admission's short lock so producer order is kept.
        processingQueue.async { [weak self] in
            guard let self else { return }
            defer {
                self.lock.lock()
                self.queuedBuffers -= 1
                self.queuedSeconds = max(0, self.queuedSeconds - duration)
                self.lock.unlock()
            }
            self.process(samples: samples, sampleRate: sampleRate, generation: generation)
        }
    }

    private func process(samples: [Float], sampleRate: Double, generation: Int) {
        lock.lock()
        let current = !stopped && self.generation == generation
        lock.unlock()
        guard current else { return }
        if bufferGeneration != generation {
            buffer.removeAll(keepingCapacity: true)
            newSinceSend = 0
            bufferGeneration = generation
        }
        let converted = Self.resample(samples, from: sampleRate)
        buffer.append(contentsOf: converted)
        if buffer.count > windowSamples { buffer.removeFirst(buffer.count - windowSamples) }
        newSinceSend += converted.count
        lock.lock()
        let stillCurrent = !stopped && self.generation == generation
        if stillCurrent { bufferedDuration = Double(buffer.count) / Self.sampleRate }
        lock.unlock()
        guard stillCurrent, newSinceSend >= strideSamples, !inFlight else { return }
        let window = buffer
        let peak = window.reduce(Int16(0)) { max($0, $1 == Int16.min ? Int16.max : abs($1)) }
        guard Float(peak) / Float(Int16.max) >= speechThreshold else {
            newSinceSend = 0
            return
        }
        newSinceSend = 0
        inFlight = true
        let wav = Self.wav(window)
        let transcribe = self.transcribe
        Task.detached { [weak self] in
            guard let self else { return }
            guard self.isCurrent(generation) else { self.finished(with: nil, generation: generation); return }
            let text = await transcribe(wav)
            self.finished(with: text, generation: generation)
        }
    }

    private func isCurrent(_ generation: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !stopped && self.generation == generation
    }

    public func stop() {
        lock.lock()
        stopped = true
        generation += 1
        bufferedDuration = 0
        lock.unlock()
        processingQueue.async { [weak self] in self?.buffer.removeAll() }
    }

    private func finished(with text: String?, generation: Int) {
        processingQueue.async { [weak self] in self?.inFlight = false }
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
        deliverQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let current = !self.stopped && self.generation == generation
            self.lock.unlock()
            if current { self.onTranscript(text) }
        }
    }

    // MARK: - Audio

    /// Linear resampling to 16 kHz with conversion to 16-bit integers.
    static func resample(_ input: [Float], from rate: Double) -> [Int16] {
        guard !input.isEmpty, rate.isFinite, rate >= 8000, rate <= 192000 else { return [] }
        let ratio = rate / sampleRate
        let count = Int(Double(input.count) / ratio)
        var out = [Int16]()
        out.reserveCapacity(count)
        for i in 0..<count {
            let position = Double(i) * ratio
            let lower = Int(position)
            let upper = min(lower + 1, input.count - 1)
            let fraction = Float(position - Double(lower))
            let value = input[lower] + (input[upper] - input[lower]) * fraction
            out.append(value.isFinite ? Int16(max(-1, min(1, value)) * Float(Int16.max)) : 0)
        }
        return out
    }

    /// A RIFF/WAVE container: mono, 16-bit integer PCM at 16 kHz.
    static func wav(_ samples: [Int16]) -> Data {
        var data = Data()
        func put<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        let byteCount = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36) + byteCount)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); put(UInt32(16))
        put(UInt16(1)); put(UInt16(1))                               // PCM, mono
        put(UInt32(sampleRate)); put(UInt32(sampleRate) * 2)         // rate, byte rate
        put(UInt16(2)); put(UInt16(16))                              // block align, bits
        data.append(contentsOf: Array("data".utf8)); put(byteCount)
        for sample in samples { put(sample) }
        return data
    }
}
