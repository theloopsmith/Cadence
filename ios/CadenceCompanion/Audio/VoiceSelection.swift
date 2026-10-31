import AVFoundation
import Foundation

/// One installed speech voice, independent of AVFoundation so the choice can
/// be tested.
public struct VoiceCandidate: Equatable, Identifiable {
    public enum Quality: Int, Comparable {
        case standard = 0, enhanced = 1, premium = 2

        public static func < (lhs: Quality, rhs: Quality) -> Bool { lhs.rawValue < rhs.rawValue }

        public var word: String {
            switch self {
            case .standard: return "Basic"
            case .enhanced: return "Enhanced"
            case .premium: return "Premium"
            }
        }
    }

    public var id: String { identifier }
    public let identifier: String
    public let name: String
    public let language: String
    public let quality: Quality

    public init(identifier: String, name: String, language: String, quality: Quality) {
        self.identifier = identifier
        self.name = name
        self.language = language
        self.quality = quality
    }

    public init(_ voice: AVSpeechSynthesisVoice) {
        let quality: Quality
        switch voice.quality {
        case .premium: quality = .premium
        case .enhanced: quality = .enhanced
        default: quality = .standard
        }
        self.init(identifier: voice.identifier, name: voice.name, language: voice.language, quality: quality)
    }

    public static var installed: [VoiceCandidate] {
        AVSpeechSynthesisVoice.speechVoices().map(VoiceCandidate.init)
    }
}

/// Picks the most natural English voice on the phone.
public enum VoiceSelection {
    /// Novelty, robotic screen reader, or sound effect voices that must never
    /// be used for a wearer who relies on hearing every word.
    private static let excludedSubstrings: [String] = [
        "albert", "bad news", "badnews", "bahh", "bells", "boing", "bubbles",
        "cellos", "deranged", "good news", "goodnews", "hysterical", "junior",
        "organ", "princess", "ralph", "trinoids", "whisper", "zarvox", "wobble",
        "jester", "superstar", "fred", "kathy",
        "eloquence", "eddy", "flo", "grandma", "grandpa", "reed", "rocko", "sandy", "shelley"
    ]

    /// Preferred natural human voices in priority order.
    private static let preferredHumanNames: [String] = [
        "siri", "nora", "aaron", "alex", "samantha", "ava", "allison", "susan",
        "zoe", "tom", "evan", "daniel", "karen", "serena", "oliver", "rishi", "moira", "tessa"
    ]

    /// Checks whether a voice is a clear, natural human voice suitable for spoken prompts.
    public static func isNaturalHumanVoice(_ voice: VoiceCandidate) -> Bool {
        let nameLower = voice.name.lowercased()
        let idLower = voice.identifier.lowercased()
        for excluded in excludedSubstrings {
            if nameLower == excluded || nameLower.contains(excluded) || idLower.contains(excluded) {
                return false
            }
        }
        return true
    }

    private static func preferenceRank(name: String) -> Int {
        let lower = name.lowercased()
        for (i, preferred) in preferredHumanNames.enumerated() {
            if lower.contains(preferred) { return i }
        }
        return 999
    }

    /// The chosen voice if it is still installed and is a natural human voice;
    /// otherwise the highest quality American English voice, then any English voice.
    public static func best(from voices: [VoiceCandidate], preferred: String?) -> VoiceCandidate? {
        let validChoices = choices(from: voices)
        if let preferred, let match = validChoices.first(where: { $0.identifier == preferred }) {
            return match
        }
        return validChoices.first
    }

    /// English voices, highest quality first, American English first within a tier,
    /// avoiding novelty or super-compact voices.
    public static func choices(from voices: [VoiceCandidate]) -> [VoiceCandidate] {
        voices
            .filter { $0.language.hasPrefix("en") && isNaturalHumanVoice($0) }
            .sorted { lhs, rhs in
                // 1. Higher quality tier first (Premium > Enhanced > Standard)
                if lhs.quality != rhs.quality { return lhs.quality > rhs.quality }

                // 2. Prefer American English within same quality tier
                let us0 = lhs.language == "en-US", us1 = rhs.language == "en-US"
                if us0 != us1 { return us0 }

                // 3. Prefer standard/compact over downsampled super-compact
                let super0 = lhs.identifier.contains("super-compact")
                let super1 = rhs.identifier.contains("super-compact")
                if super0 != super1 { return !super0 }

                // 4. Preferred natural human voice names (Nora, Samantha, Ava, Alex...)
                let rank0 = preferenceRank(name: lhs.name)
                let rank1 = preferenceRank(name: rhs.name)
                if rank0 != rank1 { return rank0 < rank1 }

                // 5. Alphabetical fallback
                return lhs.name < rhs.name
            }
    }

    /// Only the basic voices are installed; a free download sounds far better.
    public static func betterVoiceAvailableToDownload(installed: [VoiceCandidate]) -> Bool {
        !choices(from: installed).contains { $0.quality >= .enhanced }
    }
}
