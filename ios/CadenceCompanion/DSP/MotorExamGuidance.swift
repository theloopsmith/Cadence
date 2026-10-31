import Foundation

/// Shared displayed text and spoken chunks keep every check comparable.
public enum MotorExamGuidance {
    public static let writingChunks = ["The quick brown fox", "jumps over", "the lazy dog."]
    public static let writingSentence = writingChunks.joined(separator: " ")
    public static let voiceReady = "First, sit comfortably. Use a comfortable breath and voice. Say ready, or tap Start Voice Test. Wait until I say begin, then hold a steady ah for five seconds. You can skip this step."
    public static let writingIntro = "Next is handwriting. Sit comfortably with paper and a pen. Write at your usual size. I will read the sentence in three short parts, with time to write each part."
    public static let writingFinish = "Take your time to finish. You can say repeat to hear the sentence again. When you are ready, look at the whole line through your glasses and say take a photo. Or say skip."
    public static let walkReady = "Next is a ten second walk. Only do this if you feel steady and have a clear path. Keep your usual walking aid if you use one, and keep the phone in a pocket. Say ready to begin, or skip."
}
