import Foundation

/// Input is a scoped resource, not a permanent launch-time audio category.
public enum AudioInputOwner: Hashable { case companion, transcript, checkIn, motorVoice }
public struct AudioInputOwnership {
    private var owners: Set<AudioInputOwner> = []
    public init() {}
    public var requiresInput: Bool { !owners.isEmpty }
    public mutating func acquire(_ owner: AudioInputOwner) { owners.insert(owner) }
    public mutating func release(_ owner: AudioInputOwner) { owners.remove(owner) }
}
