import Foundation

/// The current task owns short answers; recognition errors must not navigate home.
public enum CompanionStep: Equatable {
    case general, motorIntro, motorVoiceReady, motorRecording, handwriting, walkReady, walking, completed
    case surroundings, cameraPreview, photoReview, analyzing, medication, medicationSetup, meal, mealSaved, settings

    public var guidance: String {
        switch self {
        case .motorIntro: return "We're still in your motor check. Say start to begin, or cancel to leave."
        case .motorVoiceReady: return "We're at the voice step. Say ready to record a steady ah for five seconds, or skip."
        case .motorRecording: return "The voice recording is in progress. I'll listen again when it finishes."
        case .handwriting: return "We're at the writing step. Look at your written line and say take a photo, or skip."
        case .walkReady: return "We're at the walking step. If you're comfortable and have a clear path, say ready. You can also say skip."
        case .walking: return "The timed walk is running. Say finish to end it early."
        case .completed: return "Your motor check is finished. Say done to close it."
        case .surroundings: return "We're checking your surroundings. Say take a photo, or retry to try the last photo again."
        case .cameraPreview: return "Your glasses camera is open. Say take a photo when you're ready."
        case .photoReview: return "I still have your photo. Say use this photo, use it, or retake."
        case .analyzing: return "I'm still checking the photo or saving this step. You can wait, or say cancel to leave."
        case .medicationSetup: return "Your routine has unsaved changes. Say save routine to keep them, or discard changes to go back."
        case .medication: return "We're reviewing your saved medication routine. Tell me if you've taken your medication, or ask for your next dose time."
        case .meal: return "Take an optional meal photo, or say ready to log the meal time without a photo. Say done to leave."
        case .mealSaved: return "Your meal is saved. Say another meal to make a new entry, or done to close."
        case .settings: return "Settings are open. Finish setup or sign-in on the phone, then say done to return."
        case .general: return "Tell me which part you want help with, or say cancel to leave this screen."
        }
    }

    public func resolve(_ text: String) -> CompanionIntent? {
        let t = CompanionIntent.normalized(text)
        switch self {
        case .medicationSetup:
            if ["save", "save routine", "save medications", "save changes", "done"].contains(t) { return .finish }
            if ["discard", "discard changes"].contains(t) { return .cancel }
        case .mealSaved:
            if ["another meal", "log another meal", "new meal"].contains(t) { return .retry }
        case .photoReview:
            if ["yes", "yes please", "use it", "use that", "use the picture", "use this picture", "save it", "looks good", "that's good", "that one", "okay", "ok"].contains(t) { return .usePhoto }
            if ["no", "no thanks", "another one"].contains(t) { return .retake }
        case .motorIntro, .motorVoiceReady, .walkReady, .handwriting, .cameraPreview, .meal:
            if ["yes", "yes please", "go ahead", "let's go", "continue", "okay", "ok"].contains(t) { return .start }
        case .walking:
            if ["stop", "stop now", "that's enough"].contains(t) { return .finish }
        default: break
        }
        return nil
    }
}
