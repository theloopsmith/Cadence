import Foundation

public enum HomeMotorExamStep {
    case idle
    case task1PromptedVoice
    case task2PromptedHandwriting
    case task3PromptedTimedWalk
    case completed
}

/// Pipeline 6 (Demo-Critical P0): Guided 3-Step Home Motor Exam state machine.
public final class HomeMotorExamManager {
    public private(set) var currentStep: HomeMotorExamStep = .idle

    public init() {}

    public func startExam() {
        currentStep = .task1PromptedVoice
        AudioCueEngine.shared.speakPrompt(
            "Step 1: Take a deep breath and say Ahhh steadily for 5 seconds, then read today's sentence.",
            priority: 2
        )
    }

    public func advanceToHandwriting() {
        currentStep = .task2PromptedHandwriting
        AudioCueEngine.shared.speakPrompt(
            "Step 2: Write the test sentence on your pad, then look down at the line.",
            priority: 2
        )
    }

    public func advanceToTimedWalk() {
        currentStep = .task3PromptedTimedWalk
        AudioCueEngine.shared.speakPrompt(
            "Step 3: Stand up when ready and walk forward in a straight line for 10 seconds.",
            priority: 2
        )
    }

    public func completeExam(compositeScore: Double) {
        currentStep = .completed
        AudioCueEngine.shared.speakPrompt(
            String(format: "Motor check complete. Your composite motor score is %.0f out of 100.", compositeScore),
            priority: 2
        )
    }
}
