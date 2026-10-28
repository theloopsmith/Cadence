import Foundation

/// Sends one JSON request and returns the response body. Swappable for tests.
public protocol JSONTransporting {
    func send(_ request: URLRequest, bearerToken: String) async throws -> Data
}

public enum CadenceAPIError: Error, LocalizedError {
    case badURL
    case httpStatus(Int)
    case emptyBody

    public var errorDescription: String? {
        switch self {
        case .badURL: return "The backend address is not a valid URL."
        case let .httpStatus(code): return "The backend returned HTTP \(code)."
        case .emptyBody: return "The backend returned an empty response."
        }
    }
}

public struct URLSessionJSONTransport: JSONTransporting {
    public let timeoutSec: TimeInterval

    public init(timeoutSec: TimeInterval = 8.0) {
        self.timeoutSec = timeoutSec
    }

    public func send(_ request: URLRequest, bearerToken: String) async throws -> Data {
        var req = request
        req.timeoutInterval = timeoutSec
        req.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        if req.httpBody != nil {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw CadenceAPIError.emptyBody }
        guard (200...299).contains(http.statusCode) else {
            throw CadenceAPIError.httpStatus(http.statusCode)
        }
        return data
    }
}

// MARK: - Response types

public struct RealityCheckResult: Decodable {
    public let eventUUID: String
    public let samVerified: Bool
    public let livingSubjectPresent: Bool
    public let chosenInanimateLabel: String?
    public let templateID: String
    public let spokenResponse: String
    public let verifiedMasks: [DetectedMask]
    public let latencyMs: Int

    public var detectedLabels: [String] { verifiedMasks.map(\.label) }

    enum CodingKeys: String, CodingKey {
        case eventUUID = "event_uuid"
        case samVerified = "sam_verified"
        case livingSubjectPresent = "living_subject_present"
        case chosenInanimateLabel = "chosen_inanimate_label"
        case templateID = "template_id"
        case spokenResponse = "spoken_response"
        case verifiedMasks = "verified_masks"
        case latencyMs = "latency_ms"
    }
}

public struct DetectedMask: Decodable {
    public let label: String
    public let confidence: Double
}

public struct HandwritingResult: Decodable {
    public let eventUUID: String
    public let measured: Bool
    public let opencvDecayPct: Double?
    public let handwritingScore: Double?
    public let micrographiaDetected: Bool
    public let spokenResponse: String

    enum CodingKeys: String, CodingKey {
        case eventUUID = "event_uuid"
        case measured
        case opencvDecayPct = "opencv_cc_decay_pct"
        case handwritingScore = "handwriting_score"
        case micrographiaDetected = "micrographia_detected"
        case spokenResponse = "spoken_response"
    }
}

public enum HandwritingSourceContext: String {
    case ambient
    case homeMotorExam = "home_motor_exam"
}

public struct MealProteinResult: Decodable {
    public struct Item: Decodable {
        public let label: String
        public let estimatedGrams: Double

        enum CodingKeys: String, CodingKey {
            case label
            case estimatedGrams = "estimated_grams"
        }
    }

    public let eventUUID: String
    public let estimatedProteinGrams: Double
    public let plateDetected: Bool
    public let conflictDetected: Bool
    public let items: [Item]
    public let spokenResponse: String

    enum CodingKeys: String, CodingKey {
        case eventUUID = "event_uuid"
        case estimatedProteinGrams = "estimated_protein_grams"
        case plateDetected = "plate_detected"
        case conflictDetected = "conflict_detected"
        case items
        case spokenResponse = "spoken_response"
    }
}

public struct ReportSummary: Decodable {
    public let onPct: Double
    public let wearingOffPct: Double
    public let offPct: Double
    public let noDosePct: Double
    public let fogCount: Int
    public let fallCount: Int
    public let fallCandidateResolvedCount: Int
    public let latestExamScore: Double?

    enum CodingKeys: String, CodingKey {
        case onPct = "on_pct"
        case wearingOffPct = "wearing_off_pct"
        case offPct = "off_pct"
        case noDosePct = "no_dose_pct"
        case fogCount = "fog_count"
        case fallCount = "fall_count"
        case fallCandidateResolvedCount = "fall_candidate_resolved_count"
        case latestExamScore = "latest_exam_score"
    }
}

public struct DiaryBucket: Decodable, Identifiable {
    public var id: String { labelHHMM }
    public let labelHHMM: String
    public let clinicalState: String
    public let symptomBurdenScore: Double

    enum CodingKeys: String, CodingKey {
        case labelHHMM = "label_hhmm"
        case clinicalState = "clinical_state"
        case symptomBurdenScore = "symptom_burden_score"
    }
}

public struct NeurologistReport: Decodable {
    public let patientID: String
    public let summary: ReportSummary
    public let buckets: [DiaryBucket]
    public let clinicalNarrative: String

    enum CodingKeys: String, CodingKey {
        case patientID = "patient_id"
        case summary = "summary_stats"
        case buckets = "buckets_24h"
        case clinicalNarrative = "clinical_narrative"
    }
}

// MARK: - Client

/// Typed access to the interactive backend endpoints: the ones where the
/// wearer is waiting for an answer. Fire-and-forget telemetry still goes
/// through `EventSyncManager`.
public struct CadenceAPIClient {
    public let baseURL: String
    public let bearerToken: String
    private let transport: JSONTransporting
    private let decoder = JSONDecoder()

    public init(
        baseURL: String,
        bearerToken: String,
        transport: JSONTransporting = URLSessionJSONTransport()
    ) {
        self.baseURL = baseURL
        self.bearerToken = bearerToken
        self.transport = transport
    }

    public func realityCheck(question: String, jpeg: Data) async throws -> RealityCheckResult {
        try await post(
            "/api/v1/reality-check",
            body: [
                "event_uuid": UUID().uuidString,
                "timestamp_utc": Self.nowISO(),
                "user_query": question,
                "image_base64": jpeg.base64EncodedString(),
            ]
        )
    }

    public func analyzeHandwriting(
        jpeg: Data,
        sourceContext: HandwritingSourceContext = .ambient
    ) async throws -> HandwritingResult {
        try await post(
            "/api/v1/handwriting/analyze",
            body: [
                "event_uuid": UUID().uuidString,
                "timestamp_utc": Self.nowISO(),
                "image_base64": jpeg.base64EncodedString(),
                "source_context": sourceContext.rawValue,
            ]
        )
    }

    public func logMeal(jpeg: Data) async throws -> MealProteinResult {
        try await post(
            "/api/v1/medication/meal-protein",
            body: [
                "event_uuid": UUID().uuidString,
                "timestamp_utc": Self.nowISO(),
                "image_base64": jpeg.base64EncodedString(),
            ]
        )
    }

    public func logDose(medicationName: String = "Levodopa/Carbidopa") async throws {
        struct Ack: Decodable { let status: String }
        let _: Ack = try await post(
            "/api/v1/medication/dose",
            body: [
                "event_uuid": UUID().uuidString,
                "timestamp_utc": Self.nowISO(),
                "medication_name": medicationName,
            ]
        )
    }

    public func fetchReport() async throws -> NeurologistReport {
        guard let url = URL(string: "\(baseURL)/api/v1/report/neurologist") else {
            throw CadenceAPIError.badURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let data = try await transport.send(request, bearerToken: bearerToken)
        return try decoder.decode(NeurologistReport.self, from: data)
    }

    // MARK: - Internals

    private func post<T: Decodable>(_ path: String, body: [String: Any]) async throws -> T {
        guard let url = URL(string: "\(baseURL)\(path)") else { throw CadenceAPIError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        let data = try await transport.send(request, bearerToken: bearerToken)
        guard !data.isEmpty else { throw CadenceAPIError.emptyBody }
        return try decoder.decode(T.self, from: data)
    }

    private static func nowISO() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}
