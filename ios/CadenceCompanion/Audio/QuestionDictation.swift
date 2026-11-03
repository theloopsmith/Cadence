import Combine
import Foundation

/// One explicitly requested question owns the shared microphone until stopped.
/// Permission replies, transcript callbacks and audio teardown are fenced by turn.
@MainActor
public final class QuestionDictation: ObservableObject {
    public enum Phase: Equatable { case idle, preparing, listening }
    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var transcript = ""
    @Published public private(set) var error: String?
    public var isActive: Bool { phase != .idle }

    private let listener: TranscriptListening
    private let permission: () async -> String?
    private let acquire: () async -> Void
    private let release: () -> Void
    private let canStart: () -> Bool
    private let echoActive: () -> Bool
    private let readyTimeout: Double
    private let silenceTimeout: Double
    private let maximumDuration: Double
    private var operation = UUID()
    private var task: Task<Void, Never>?
    private var cleanup: Task<Void, Never>?
    private var ownsMicrophone = false
    private var lastChange: Double?

    public init(listener: TranscriptListening, permission: @escaping () async -> String?,
                acquire: @escaping () async -> Void, release: @escaping () -> Void,
                canStart: @escaping () -> Bool = { true }, echoActive: @escaping () -> Bool = { false },
                readyTimeout: Double = 6, silenceTimeout: Double = 4, maximumDuration: Double = 40) {
        self.listener = listener; self.permission = permission; self.acquire = acquire; self.release = release
        self.canStart = canStart; self.echoActive = echoActive
        self.readyTimeout = max(0.01, readyTimeout)
        self.silenceTimeout = max(0.01, silenceTimeout)
        self.maximumDuration = max(0.01, maximumDuration)
    }

    public func start() {
        stop()
        guard canStart() else {
            error = "Voice input is paused. Finish the safety check or reopen Cadence after a reset."
            return
        }
        error = nil; transcript = ""; lastChange = nil; phase = .preparing
        let id = UUID(); operation = id
        let previousCleanup = cleanup
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            await previousCleanup?.value
            guard self.current(id) else { return }
            let problem = await self.permission()
            guard self.current(id) else { return }
            if let problem { self.finish(problem); return }
            guard self.canStart() else { self.finish("Voice input is paused for the current check-in."); return }
            self.ownsMicrophone = true
            await self.acquire()
            guard self.current(id) else { return }
            guard self.canStart() else { self.finish("Voice input is paused for the current check-in."); return }
            let preparingAt = ProcessInfo.processInfo.systemUptime
            while self.echoActive() {
                guard self.current(id) else { return }
                guard ProcessInfo.processInfo.systemUptime - preparingAt < self.readyTimeout else {
                    self.finish("Wait for spoken audio to finish, then try speaking your question again."); return
                }
                do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return }
            }
            guard self.current(id) else { return }
            self.listener.startQuestionDictation { [weak self] text in
                Task { @MainActor [weak self] in
                    guard let self, self.current(id), self.ownsMicrophone else { return }
                    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty, text != self.transcript else { return }
                    self.transcript = text
                    self.lastChange = ProcessInfo.processInfo.systemUptime
                }
            }
            let startedAt = ProcessInfo.processInfo.systemUptime
            var readyAt: Double?
            while self.current(id) {
                let now = ProcessInfo.processInfo.systemUptime
                guard self.canStart() else { self.finish("Voice input is paused for the current check-in."); return }
                if let failure = self.listener.failureReason {
                    self.finish(failure); return
                }
                if !self.listener.isListening {
                    self.finish(self.transcript.isEmpty ? "The microphone stopped before a question was heard. Try again or type your question." : nil)
                    return
                }
                if readyAt == nil {
                    if self.listener.isReady { readyAt = now; self.phase = .listening }
                    else if now - startedAt >= self.readyTimeout {
                        self.finish("The microphone did not become ready. Check the audio connection, then try again."); return
                    }
                }
                if let changed = self.lastChange, now - changed >= self.silenceTimeout {
                    self.finish(nil); return
                }
                if now - (readyAt ?? startedAt) >= self.maximumDuration {
                    self.finish(self.transcript.isEmpty ? "No question was heard. Try again, type a question, or choose one below." : nil)
                    return
                }
                do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return }
            }
        }
    }

    public func stop() {
        operation = UUID(); task?.cancel(); task = nil; phase = .idle
        guard ownsMicrophone else { return }
        ownsMicrophone = false
        listener.stopListening()
        let listener = listener, release = release
        cleanup = Task { @MainActor in
            await listener.waitUntilStopped()
            release()
        }
    }

    private func current(_ id: UUID) -> Bool {
        operation == id && phase != .idle && !Task.isCancelled
    }
    private func finish(_ problem: String?) { stop(); error = problem }
}
