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
    /// The chosen voice if it is still installed; otherwise the highest
    /// quality American English voice, then any English voice.
    public static func best(from voices: [VoiceCandidate], preferred: String?) -> VoiceCandidate? {
        if let preferred, let match = voices.first(where: { $0.identifier == preferred }) {
            return match
        }
        return choices(from: voices).first
    }

    /// English voices, highest quality first, American English first within a tier.
    public static func choices(from voices: [VoiceCandidate]) -> [VoiceCandidate] {
        voices
            .filter { $0.language.hasPrefix("en") }
            .sorted {
                if $0.quality != $1.quality { return $0.quality > $1.quality }
                let us0 = $0.language == "en-US", us1 = $1.language == "en-US"
                if us0 != us1 { return us0 }
                return $0.name < $1.name
            }
    }

    /// Only the basic voices are installed; a free download sounds far better.
    public static func betterVoiceAvailableToDownload(installed: [VoiceCandidate]) -> Bool {
        !choices(from: installed).contains { $0.quality >= .enhanced }
    }
}
