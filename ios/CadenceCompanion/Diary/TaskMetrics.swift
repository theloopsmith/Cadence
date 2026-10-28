import Foundation

/// The raw measurements from one motor check. Nil means the step was not
/// measured; nothing is ever filled in for it.
public struct TaskMetricsRecord: Codable, Equatable {
    public var date: Date
    public var voiceMeanDbfs: Double?
    public var handwritingDecayPct: Double?
    public var walkStepsPerMinute: Double?
    public var walkFreezes: Int?

    public init(
        date: Date,
        voiceMeanDbfs: Double?,
        handwritingDecayPct: Double?,
        walkStepsPerMinute: Double?,
        walkFreezes: Int?
    ) {
        self.date = date
        self.voiceMeanDbfs = voiceMeanDbfs
        self.handwritingDecayPct = handwritingDecayPct
        self.walkStepsPerMinute = walkStepsPerMinute
        self.walkFreezes = walkFreezes
    }
}

/// Motor check results as plain trends: what was measured, and how it
/// compares with the previous check. No scores, no medication states.
public enum TaskMetricsSummary {
    public struct Line: Equatable {
        public let systemImage: String
        public let title: String
        public let value: String
        public let comparison: String?
    }

    private static let notMeasured = "Not measured this time"

    public static func lines(current: TaskMetricsRecord, previous: TaskMetricsRecord?) -> [Line] {
        [letterLine(current, previous), voiceLine(current, previous), walkLine(current, previous)]
    }

    /// One short line for the diary.
    public static func diaryDetail(_ record: TaskMetricsRecord) -> String {
        var parts: [String] = []
        if let pct = record.handwritingDecayPct {
            parts.append("Letters " + letterPhrase(pct, lowercaseSame: true))
        }
        if let spm = record.walkStepsPerMinute {
            parts.append("\(Int(spm.rounded())) steps a minute")
        }
        return parts.isEmpty ? "Motor check done" : parts.joined(separator: " · ")
    }

    // MARK: - Lines

    private static func letterLine(_ c: TaskMetricsRecord, _ p: TaskMetricsRecord?) -> Line {
        guard let pct = c.handwritingDecayPct else {
            return Line(systemImage: "pencil.line", title: "Letter size", value: notMeasured, comparison: nil)
        }
        let previous = p?.handwritingDecayPct.map { "Last time: " + shortLetterPhrase($0) }
        return Line(
            systemImage: "pencil.line",
            title: "Letter size",
            value: letterPhrase(pct, lowercaseSame: false),
            comparison: previous
        )
    }

    private static func voiceLine(_ c: TaskMetricsRecord, _ p: TaskMetricsRecord?) -> Line {
        guard let db = c.voiceMeanDbfs else {
            return Line(systemImage: "waveform", title: "Voice", value: notMeasured, comparison: nil)
        }
        var comparison: String?
        if let before = p?.voiceMeanDbfs {
            let delta = Int((db - before).rounded())
            if abs(delta) <= 1 {
                comparison = "About the same as last time"
            } else {
                comparison = "\(abs(delta)) dB \(delta > 0 ? "louder" : "quieter") than last time"
            }
        }
        return Line(
            systemImage: "waveform",
            title: "Voice",
            value: "\(Int(db.rounded()))".replacingOccurrences(of: "-", with: "−") + " dB",
            comparison: comparison
        )
    }

    private static func walkLine(_ c: TaskMetricsRecord, _ p: TaskMetricsRecord?) -> Line {
        guard let spm = c.walkStepsPerMinute else {
            return Line(systemImage: "figure.walk", title: "Walking", value: notMeasured, comparison: nil)
        }
        var value = "\(Int(spm.rounded())) steps a minute"
        if let freezes = c.walkFreezes, freezes > 0 {
            value += " · \(freezes) \(freezes == 1 ? "pause" : "pauses")"
        }
        var comparison: String?
        if let before = p?.walkStepsPerMinute {
            let delta = Int((spm - before).rounded())
            if abs(delta) <= 2 {
                comparison = "About the same as last time"
            } else {
                comparison = "\(abs(delta)) \(delta > 0 ? "more" : "fewer") steps a minute than last time"
            }
        }
        return Line(systemImage: "figure.walk", title: "Walking", value: value, comparison: comparison)
    }

    private static func letterPhrase(_ pct: Double, lowercaseSame: Bool) -> String {
        if abs(pct) < 5 {
            return (lowercaseSame ? "about" : "About") + " the same size across the line"
        }
        return "\(Int(abs(pct).rounded()))% \(pct < 0 ? "smaller" : "larger") across the line"
    }

    private static func shortLetterPhrase(_ pct: Double) -> String {
        if abs(pct) < 5 { return "about the same size" }
        return "\(Int(abs(pct).rounded()))% \(pct < 0 ? "smaller" : "larger")"
    }
}

/// Motor check results kept on the phone, so trends work offline.
public struct TaskMetricsHistory {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static var `default`: TaskMetricsHistory {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return TaskMetricsHistory(directory: docs.appendingPathComponent("MotorChecks", isDirectory: true))
    }

    private var fileURL: URL { directory.appendingPathComponent("history.json") }

    public func all() -> [TaskMetricsRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return ((try? decoder.decode([TaskMetricsRecord].self, from: data)) ?? []).sorted { $0.date < $1.date }
    }

    public func latest() -> TaskMetricsRecord? {
        all().last
    }

    public func append(_ record: TaskMetricsRecord) throws {
        var records = all()
        records.append(record)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(records).write(to: fileURL, options: .atomic)
    }
}
