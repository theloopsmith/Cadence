import Foundation

/// Read-only questions are separate from commands and can never create records or calls.
public enum CompanionQuestion: Equatable {
    case doseHistory, nextDose, medicationPlan, lastMotorCheck, caregiverStatus, capabilities, motorExplanation

    public static func parse(_ raw: String) -> CompanionQuestion? {
        let t = CompanionIntent.normalized(raw)
        let question = ["what", "when", "which", "who", "why", "how", "did", "have", "has", "is", "are", "am", "can", "could", "tell", "show", "i'm not sure", "i am not sure", "i don't remember", "i cannot remember"].contains { t == $0 || t.hasPrefix($0 + " ") }
        guard question else { return nil }
        func has(_ words: [String]) -> Bool { words.contains { (" " + t + " ").contains(" " + $0 + " ") } }
        if has(["caregiver", "care partner", "help request", "alert"]), has(["acknowledged", "responded", "respond", "received", "receive", "reached", "status"]) { return .caregiverStatus }
        if has(["motor", "movement", "check", "exam"]), has(["last", "latest", "recent", "results"]) { return .lastMotorCheck }
        if has(["why", "how"]), has(["motor", "handwriting", "writing", "voice test", "walking test"]) { return .motorExplanation }
        if has(["schedule", "times"]), has(["medication", "medications", "medicine", "medicines", "pills", "dose"]) { return .medicationPlan }
        if has(["next dose", "next medication", "next medicine"])
            || (has(["due", "time", "times", "schedule"] ) && has(["medicine", "medication", "pills", "pill", "dose"])) { return .nextDose }
        if has(["took", "taken", "take", "recorded", "logged", "last dose"]), has(["medication", "medicine", "pill", "pills", "dose", "last take", "last took"]) { return .doseHistory }
        if has(["medications", "medicines", "medication plan", "my medication", "my medicine", "my pills"]) { return .medicationPlan }
        if has(["what can you do", "what can i ask", "how can you help", "what do you do"]) { return .capabilities }
        return nil
    }
}

public enum CompanionAnswers {
    public static let capabilities = "You can ask when your next saved medication time is, what doses you recorded, or about your latest motor check. I can also guide a motor check, help with a photo, or open a caregiver call after confirmation."

    public static func medication(_ question: CompanionQuestion, text: String, plan: [MedicationSchedule], events: [DiaryEvent], now: Date, calendar: Calendar = .current) -> String {
        guard !plan.isEmpty else { return "There are no saved medications on this phone. Your care partner can add the prescribed names and times in Settings, under Medications." }
        let t = " " + CompanionIntent.normalized(text) + " "
        let matches = plan.filter { t.contains(" " + CompanionIntent.normalized($0.medicationName) + " ") }
        let relevant = matches.isEmpty ? plan : matches
        let formatter = DateFormatter(); formatter.dateStyle = .medium; formatter.timeStyle = .short; formatter.calendar = calendar
        if question == .medicationPlan {
            let time = DateFormatter(); time.timeStyle = .short; time.calendar = calendar
            return relevant.map { medication in
                let times = medication.doseDates(on: now).map { time.string(from: $0) }
                return times.isEmpty ? "\(medication.medicationName) has no saved reminder times."
                    : "Your saved times for \(medication.medicationName) are \(times.joined(separator: ", "))."
            }.joined(separator: " ") + " This is the plan configured on this phone; it does not change your prescription."
        }
        if question == .nextDose {
            let upcoming = relevant.compactMap { item in item.nextDose(after: now).map { (item.medicationName, $0) } }.sorted { $0.1 < $1.1 }
            guard let first = upcoming.first else { return "Those medications have no saved reminder times. Check the prescribed schedule with your care partner." }
            let atSameTime = upcoming.filter { $0.1 == first.1 }.map { $0.0 }.joined(separator: ", ")
            return "The next saved reminder is for \(atSameTime), \(formatter.string(from: first.1)). That's your configured time, not a recommendation to take another dose."
        }
        let scope = t.contains(" yesterday ") ? "yesterday" : (t.contains(" today ") ? "today" : "the last 30 days")
        let records = relevant.map { medication -> String in
            let matching = events.filter { $0.kind == .doseTaken && $0.detail == medication.medicationName && $0.at <= now }
            guard let latest = matching.max(by: { $0.at < $1.at }) else { return "I found no dose record for \(medication.medicationName) in \(scope)." }
            return "You recorded \(medication.medicationName) at \(formatter.string(from: latest.at))."
        }
        return records.joined(separator: " ") + " These are records on this phone, not proof of ingestion. If you're unsure, ask your caregiver or pharmacist before deciding what to do."
    }
}
