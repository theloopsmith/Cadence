import Foundation

/// Sends one JSON request and returns the response body. Swappable for tests.
public protocol JSONTransporting {
    func send(_ request: URLRequest, bearerToken: String) async throws -> Data
}

public enum CadenceAPIError: Error, LocalizedError {
    case badURL
    case httpStatus(Int)
    case emptyBody
    case dataGenerationChanged(Int)

    public var errorDescription: String? {
        switch self {
        case .badURL: return "The backend address is not a valid URL."
        case .httpStatus(401): return "Sign in to this Cadence server again. Your previous login is missing or no longer accepted."
        case let .httpStatus(code): return "The backend returned HTTP \(code)."
        case .emptyBody: return "The backend returned an empty response."
        case .dataGenerationChanged: return "Server data was erased. This attempt was not saved. Record a new action after syncing."
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
        if !bearerToken.isEmpty {
            req.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        if req.httpBody != nil {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw CadenceAPIError.emptyBody }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 409,
               let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               body["error"] as? String == "data_generation_changed", let generation = body["data_generation"] as? Int, generation >= 0 {
                throw CadenceAPIError.dataGenerationChanged(generation)
            }
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
    public let confidence: Double?
}

public struct ServerConnectionInfo: Decodable {
    public let service: String
    public let serverID: String
    public let patientID: String
    public let dataGeneration: Int?
    public init(service: String, serverID: String, patientID: String, dataGeneration: Int? = nil) {
        self.service = service; self.serverID = serverID; self.patientID = patientID; self.dataGeneration = dataGeneration
    }
    enum CodingKeys: String, CodingKey { case service, serverID = "server_id", patientID = "patient_id", dataGeneration = "data_generation" }
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
    public let estimatedProteinGrams: Double?
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

public struct FallDeliveryStatus: Decodable {
    public let eventUUID: String
    public let contactState: String
    public let providerAccepted: Bool
    public let caregiverAcknowledged: Bool
    public let simulated: Bool
    enum CodingKeys: String, CodingKey {
        case eventUUID = "event_uuid", contactState = "contact_state", providerAccepted = "provider_accepted"
        case caregiverAcknowledged = "caregiver_acknowledged", simulated
    }
}

public struct ReportMetadata: Decodable {
    public let windowStartUTC: String
    public let windowEndUTC: String
    public let generatedAtUTC: String
    public let latestEventUTC: String?
    public let coverageNote: String
    enum CodingKeys: String, CodingKey {
        case windowStartUTC = "window_start_utc", windowEndUTC = "window_end_utc", generatedAtUTC = "generated_at_utc"
        case latestEventUTC = "latest_event_utc", coverageNote = "coverage_note"
    }
}

public struct ReportSummary: Decodable {
    public let onPct: Double?
    public let wearingOffPct: Double?
    public let offPct: Double?
    public let noDosePct: Double?
    public let fogCount: Int
    public let fallCount: Int
    public let fallCandidateResolvedCount: Int
    public let latestExamScore: Double?
    /// Doses logged in the last 24 hours. Absent from older servers.
    public let caregiverProviderAcceptedCount: Int?
    public let caregiverAcknowledgedCount: Int?
    public let simulatedAlertCount: Int?
    public let doseCount: Int?

    enum CodingKeys: String, CodingKey {
        case caregiverProviderAcceptedCount = "caregiver_provider_accepted_count"
        case caregiverAcknowledgedCount = "caregiver_acknowledged_count"
        case simulatedAlertCount = "simulated_alert_count"
        case doseCount = "dose_count"
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
    public var id: String { bucketStartUTC ?? labelHHMM }
    public let bucketStartUTC: String?
    public let observationStatus: String?
    public let labelHHMM: String
    public let clinicalState: String?
    public let symptomBurdenScore: Double?
    public let fogCount: Int?
    public let fallOccurred: Bool?
    public let hasExam: Bool?

    enum CodingKeys: String, CodingKey {
        case bucketStartUTC = "bucket_start_utc"
        case observationStatus = "observation_status"
        case labelHHMM = "label_hhmm"
        case clinicalState = "clinical_state"
        case symptomBurdenScore = "symptom_burden_score"
        case fogCount = "fog_count"
        case fallOccurred = "fall_occurred"
        case hasExam = "has_exam"
    }

    /// What happened in this half hour, counted rather than interpreted.
    public enum EventLevel: Equatable { case unknown, none, onePause, more }

    public var eventLevel: EventLevel {
        let pauses = fogCount ?? 0
        if fallOccurred == true || pauses >= 2 { return .more }
        if pauses == 1 { return .onePause }
        return observationStatus == "events_logged" || hasExam == true ? .none : .unknown
    }
}

public struct NeurologistReport: Decodable {
    public let patientID: String
    public let metadata: ReportMetadata?
    public let summary: ReportSummary
    public let buckets: [DiaryBucket]
    public let clinicalNarrative: String

    enum CodingKeys: String, CodingKey {
        case metadata = "report_metadata"
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
    public let dataGeneration: Int
    private let onDataGenerationChanged: ((Int) -> Void)?
    private let onUnauthorized: (() async -> Void)?

    public init(
        baseURL: String,
        bearerToken: String,
        transport: JSONTransporting = URLSessionJSONTransport(),
        dataGeneration: Int = 0,
        onDataGenerationChanged: ((Int) -> Void)? = nil,
        onUnauthorized: (() async -> Void)? = nil
    ) {
        self.baseURL = baseURL
        self.bearerToken = bearerToken
        self.transport = transport
        self.dataGeneration = dataGeneration
        self.onDataGenerationChanged = onDataGenerationChanged
        self.onUnauthorized = onUnauthorized
    }

    public func companionIntent(text: String, history: [String]) async throws -> CompanionIntent? {
        struct Interpretation: Decodable { let intent: String }
        let result: Interpretation = try await post("/api/v1/companion/interpret", body: [
            "text": String(text.prefix(1200)), "history": history.suffix(6).map { String($0.prefix(1200)) }
        ])
        return CompanionIntent(rawValue: result.intent)
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
            "/api/v1/meals/log",
            body: [
                "event_uuid": UUID().uuidString,
                "timestamp_utc": Self.nowISO(),
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

    public enum TranscribePurpose: String {
        case companion
        case fallCheckIn = "fall_check_in"
        case dose
    }

    /// `POST /api/v1/speech/transcribe`: Muse Voice Transcribe via the server,
    /// which holds the Meta key. Returns nil when the transcriber is unavailable.
    public func transcribe(wav: Data, purpose: TranscribePurpose, keywords: [String]) async throws -> String? {
        struct Reply: Decodable {
            let available: Bool
            let transcript: String
        }
        let reply: Reply = try await post(
            "/api/v1/speech/transcribe",
            body: [
                "audio_base64": wav.base64EncodedString(),
                "purpose": purpose.rawValue,
                "keywords": Array(keywords.prefix(10)),
            ]
        )
        return reply.available && !reply.transcript.isEmpty ? reply.transcript : nil
    }

    public struct LoginResult: Decodable {
        public let accessToken: String
        public let expiresIn: Int
        public let role: String

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
            case role
        }
    }

    /// `POST /api/v1/auth/login`. Sent without any existing token.
    public func login(username: String, password: String) async throws -> LoginResult {
        guard let url = URL(string: "\(baseURL)/api/v1/auth/login") else { throw CadenceAPIError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["username": username, "password": password])
        let data = try await transport.send(request, bearerToken: "")
        return try decoder.decode(LoginResult.self, from: data)
    }

    public struct Health: Decodable {
        public let status: String
        public let version: String
    }

    /// `GET /health`, no token required.
    public func health() async throws -> Health {
        guard let url = URL(string: "\(baseURL)/health") else { throw CadenceAPIError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let data = try await transport.send(request, bearerToken: bearerToken)
        return try decoder.decode(Health.self, from: data)
    }

    public func fallDelivery(eventUUID: String) async throws -> FallDeliveryStatus {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%")
        guard let encoded = eventUUID.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "\(baseURL)/api/v1/events/fall/\(encoded)/delivery") else { throw CadenceAPIError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let data = try await sendAuthenticated(request)
        return try decoder.decode(FallDeliveryStatus.self, from: data)
    }

    public func connectionInfo() async throws -> ServerConnectionInfo {
        guard let url = URL(string: "\(baseURL)/api/v1/device/connection") else { throw CadenceAPIError.badURL }
        var request = URLRequest(url: url); request.httpMethod = "GET"
        return try decoder.decode(ServerConnectionInfo.self, from: await sendAuthenticated(request))
    }

    public func fetchReport() async throws -> NeurologistReport {
        guard let url = URL(string: "\(baseURL)/api/v1/report/neurologist") else {
            throw CadenceAPIError.badURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let data = try await sendAuthenticated(request)
        return try decoder.decode(NeurologistReport.self, from: data)
    }

    // MARK: - Internals

    private func sendAuthenticated(_ request: URLRequest) async throws -> Data {
        do { return try await transport.send(request, bearerToken: bearerToken) }
        catch CadenceAPIError.httpStatus(401) {
            await onUnauthorized?()
            throw CadenceAPIError.httpStatus(401)
        }
    }

    private func post<T: Decodable>(_ path: String, body: [String: Any]) async throws -> T {
        guard let url = URL(string: "\(baseURL)\(path)") else { throw CadenceAPIError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(String(dataGeneration), forHTTPHeaderField: "X-Cadence-Data-Generation")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        let data: Data
        do { data = try await sendAuthenticated(request) }
        catch CadenceAPIError.dataGenerationChanged(let current) {
            onDataGenerationChanged?(current)
            throw CadenceAPIError.dataGenerationChanged(current)
        }
        guard !data.isEmpty else { throw CadenceAPIError.emptyBody }
        return try decoder.decode(T.self, from: data)
    }

    private static func nowISO() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}
