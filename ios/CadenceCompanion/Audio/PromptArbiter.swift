import Foundation

/// One active utterance, no backlog. Completion IDs fence callbacks from canceled speech.
struct PromptArbiter {
    struct Prompt: Equatable {
        let id: UUID
        let text: String
        let priority: Int
    }
    private(set) var active: Prompt?
    private var lastCuePromptAt: TimeInterval?
    var cuePromptCooldown: TimeInterval = 45

    mutating func request(_ text: String, priority: Int, now: TimeInterval, cue: Bool = false) -> Prompt? {
        if let active, active.priority < priority || active.text == text { return nil }
        if cue, let lastCuePromptAt, now - lastCuePromptAt < cuePromptCooldown { return nil }
        if cue { lastCuePromptAt = now }
        let prompt = Prompt(id: UUID(), text: text, priority: priority)
        active = prompt
        return prompt
    }
    @discardableResult
    mutating func cancel(priority: Int? = nil) -> Bool {
        guard let active, priority == nil || active.priority == priority else { return false }
        self.active = nil
        return true
    }
    mutating func finished(_ id: UUID) {
        if active?.id == id { active = nil }
    }
}
