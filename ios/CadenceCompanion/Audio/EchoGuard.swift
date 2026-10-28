import Foundation

/// Answers "is the app talking right now, or did it only just stop?" The
/// microphone hears the phone's own speaker, so anything heard in that
/// window is the prompt, not the wearer.
public protocol EchoGuarding: AnyObject {
    func isInEchoWindow(at date: Date) -> Bool
}

/// Speaking plus a short tail, because the room keeps ringing and the
/// recognizer lags the audio slightly.
public struct EchoWindow {
    public var tailSec: TimeInterval
    private var speaking = false
    private var endedAt: Date?

    public init(tailSec: TimeInterval = 0.8) {
        self.tailSec = tailSec
    }

    public mutating func speechStarted() {
        speaking = true
    }

    public mutating func speechEnded(at date: Date) {
        speaking = false
        endedAt = date
    }

    public func isActive(at date: Date) -> Bool {
        if speaking { return true }
        guard let endedAt else { return false }
        return date.timeIntervalSince(endedAt) < tailSec
    }
}

/// Turns a recognizer's running transcript into only what was said after the
/// last prompt. Recognizers return the whole session so far on every update,
/// so the prompt's words would otherwise stay in every later transcript.
public struct EchoFilteredTranscript {
    private var ignoredLength = 0

    public init() {}

    /// Returns the wearer's own words, or nil when there are none yet.
    public mutating func update(fullTranscript: String, echoActive: Bool) -> String? {
        if echoActive {
            ignoredLength = fullTranscript.count
            return nil
        }
        guard fullTranscript.count > ignoredLength else { return nil }
        let fresh = String(fullTranscript.dropFirst(ignoredLength)).trimmingCharacters(in: .whitespacesAndNewlines)
        return fresh.isEmpty ? nil : fresh
    }
}
