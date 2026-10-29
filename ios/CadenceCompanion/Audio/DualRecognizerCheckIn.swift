import Foundation

public enum CheckInRecognizer: Sendable { case local, cloud }

/// The same evidence reducer is used by live audio and the mock kit. An
/// affirmative is provisional for the full check-in window; any distress from
/// either source is latched and cannot be overwritten by a later correction.
public struct DualRecognizerCheckIn {
    public private(set) var localTranscript = ""
    public private(set) var cloudTranscript = ""
    public private(set) var distressHeard = false
    public init() {}
    public mutating func record(_ text: String, from source: CheckInRecognizer) {
        switch source { case .local: localTranscript=text; case .cloud: cloudTranscript=text }
        let normalized=FallDetector.normalizeTranscript(text)
        if FallDetector.distressAndNegationKeywords.contains(where:{ FallDetector.containsDistressPhrase(normalized,$0) }) { distressHeard=true }
    }
    public var transcriptForResolution: String {
        if distressHeard { return "help" }
        func affirmative(_ text:String)->Bool {
            let normalized=FallDetector.normalizeTranscript(text)
            return FallDetector.affirmativeCancelPhrases.contains { FallDetector.containsPhrase(normalized,$0) }
        }
        return affirmative(localTranscript) && (cloudTranscript.isEmpty || affirmative(cloudTranscript)) ? localTranscript : ""
    }
}
