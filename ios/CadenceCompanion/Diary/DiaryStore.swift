import Foundation

/// Something that happened today, worth a line in the diary.
public enum DiaryEventKind: String, Codable, CaseIterable {
    case protectionOn
    case protectionOff
    case cue
    case doseTaken
    case checkInAnswered
    case helpSent
    case environmentCheck
    case mealLogged

    public var systemImage: String {
        switch self {
        case .protectionOn: return "shield.fill"
        case .protectionOff: return "shield.slash"
        case .cue: return "metronome.fill"
        case .doseTaken: return "pills.fill"
        case .checkInAnswered: return "hand.thumbsup.fill"
        case .helpSent: return "phone.fill"
        case .environmentCheck: return "eye.fill"
        case .mealLogged: return "fork.knife"
        }
    }

    public var word: String {
        switch self {
        case .protectionOn: return "Protection on"
        case .protectionOff: return "Protection off"
        case .cue: return "Beat played"
        case .doseTaken: return "Dose taken"
        case .checkInAnswered: return "Check-in answered"
        case .helpSent: return "Help contacted"
        case .environmentCheck: return "Looked around"
        case .mealLogged: return "Meal noted"
        }
    }
}

public struct DiaryEvent: Codable, Identifiable, Equatable {
    public var id: String
    public var kind: DiaryEventKind
    public var at: Date
    public var detail: String

    public init(id: String = UUID().uuidString, kind: DiaryEventKind, at: Date, detail: String) {
        self.id = id
        self.kind = kind
        self.at = at
        self.detail = detail
    }
}

/// One JSON file per day. Local first: the diary works with no connection.
public struct DiaryStore {
    public let directory: URL
    private let calendar: Calendar

    public init(directory: URL, calendar: Calendar = .current) {
        self.directory = directory
        self.calendar = calendar
    }

    public static var `default`: DiaryStore {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return DiaryStore(directory: docs.appendingPathComponent("Diary", isDirectory: true))
    }

    public func append(_ event: DiaryEvent) throws {
        var events = try load(day: event.at)
        events.append(event)
        try save(events, day: event.at)
    }

    public func remove(id: String) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        where file.pathExtension == "json" {
            var events = try decode(file)
            let before = events.count
            events.removeAll { $0.id == id }
            if events.count != before { try write(events, to: file) }
        }
    }

    /// Events on the day containing `date`, newest first.
    public func events(on date: Date) throws -> [DiaryEvent] {
        try load(day: date).sorted { $0.at > $1.at }
    }

    /// Short statements of fact: counts today against yesterday, no judgement.
    public func plainFacts(for date: Date) throws -> [String] {
        let today = try load(day: date)
        let yesterday = try load(day: calendar.date(byAdding: .day, value: -1, to: date) ?? date)
        var facts: [String] = []

        let cuesToday = today.filter { $0.kind == .cue }.count
        let cuesYesterday = yesterday.filter { $0.kind == .cue }.count
        facts.append("\(cuesToday) \(cuesToday == 1 ? "freeze" : "freezes") today, \(cuesYesterday) yesterday")

        let doses = today.filter { $0.kind == .doseTaken }.count
        facts.append("\(doses) \(doses == 1 ? "dose" : "doses") logged today")

        let checkIns = today.filter { $0.kind == .checkInAnswered }.count
        if checkIns > 0 {
            facts.append("\(checkIns) check-in\(checkIns == 1 ? "" : "s") answered today")
        }
        let help = today.filter { $0.kind == .helpSent }.count
        if help > 0 {
            facts.append("Help was contacted \(help == 1 ? "once" : "\(help) times") today")
        }
        return facts
    }

    // MARK: - Files

    private func fileURL(day: Date) -> URL {
        let c = calendar.dateComponents([.year, .month, .day], from: day)
        let name = String(format: "%04d-%02d-%02d.json", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        return directory.appendingPathComponent(name)
    }

    private func load(day: Date) throws -> [DiaryEvent] {
        let url = fileURL(day: day)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try decode(url)
    }

    private func save(_ events: [DiaryEvent], day: Date) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try write(events, to: fileURL(day: day))
    }

    private func decode(_ url: URL) throws -> [DiaryEvent] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([DiaryEvent].self, from: Data(contentsOf: url))
    }

    private func write(_ events: [DiaryEvent], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(events).write(to: url, options: .atomic)
    }
}
