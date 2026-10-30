import XCTest
@testable import CadenceCompanion

/// Records every request and replays a canned body.
final class RecordingJSONTransport: JSONTransporting {
    struct Request {
        let url: URL
        let method: String
        let body: Data?
        let bearerToken: String
    }

    var requests: [Request] = []
    var responses: [Data] = []
    var error: Error?

    func send(_ request: URLRequest, bearerToken: String) async throws -> Data {
        requests.append(
            Request(
                url: request.url!,
                method: request.httpMethod ?? "GET",
                body: request.httpBody,
                bearerToken: bearerToken
            )
        )
        if let error { throw error }
        guard !responses.isEmpty else { return Data() }
        return responses.removeFirst()
    }
}

final class CadenceAPIClientTests: XCTestCase {
    func testTimelineTreatsMissingCoverageAsUnknownWithoutHidingRecordedEvents() throws {
        func bucket(_ body: String) throws -> DiaryBucket { try JSONDecoder().decode(DiaryBucket.self, from: Data(body.utf8)) }
        XCTAssertEqual(try bucket(#"{"label_hhmm":"10:00","fog_count":0}"#).eventLevel, .unknown)
        XCTAssertEqual(try bucket(#"{"label_hhmm":"10:00","fog_count":1}"#).eventLevel, .onePause)
        XCTAssertEqual(try bucket(#"{"label_hhmm":"10:00","observation_status":"no_observations"}"#).eventLevel, .unknown)
        XCTAssertEqual(try bucket(#"{"label_hhmm":"10:00","observation_status":"events_logged","fog_count":0}"#).eventLevel, .none)
    }
    private func makeClient(_ transport: RecordingJSONTransport) -> CadenceAPIClient {
        CadenceAPIClient(
            baseURL: "http://example.test",
            bearerToken: "device-token",
            transport: transport
        )
    }

    private func json(_ data: Data?) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: try XCTUnwrap(data))
        return try XCTUnwrap(object as? [String: Any])
    }

    /// The reality check is only grounded when the backend sees the photo.
    func testRealityCheckSendsThePhotoAndTheQuestion() async throws {
        let transport = RecordingJSONTransport()
        transport.responses = [
            Data(
                """
                {"event_uuid":"rc-1","sam_verified":true,"living_subject_present":false,
                 "chosen_inanimate_label":"coat","template_id":"REASSURE_OBJECT_ON_SEAT",
                 "spoken_response":"I can identify a coat in this photo. I cannot verify the whole scene.",
                 "verified_masks":[{"label":"coat","confidence":0.91,"area_ratio":0.08}],
                 "tts_source":"ios_avspeech_fallback","latency_ms":412}
                """.utf8
            )
        ]
        let photo = Data([0xFF, 0xD8, 0x01, 0x02])

        let result = try await makeClient(transport).realityCheck(
            question: "Is someone sitting in that chair?",
            jpeg: photo
        )

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url.path, "/api/v1/reality-check")
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.bearerToken, "device-token")
        let body = try json(request.body)
        XCTAssertEqual(body["user_query"] as? String, "Is someone sitting in that chair?")
        XCTAssertEqual(body["image_base64"] as? String, photo.base64EncodedString())
        XCTAssertNil(body["simulated_sam_masks"], "a live photo must not carry simulated masks")

        XCTAssertFalse(result.livingSubjectPresent)
        XCTAssertEqual(result.chosenInanimateLabel, "coat")
        XCTAssertEqual(result.detectedLabels, ["coat"])
        XCTAssertTrue(result.spokenResponse.hasPrefix("I can identify"))
    }

    func testHandwritingAnalysisSendsThePhotoAndReadsTheDecay() async throws {
        let transport = RecordingJSONTransport()
        transport.responses = [
            Data(
                """
                {"event_uuid":"hw-1","measured":true,"opencv_cc_decay_pct":-27.8,
                 "handwriting_score":63.5,"micrographia_detected":true,
                 "sam_3_1_decay_pct":null,"deskew_angle_deg":1.2,"letter_boxes":[],
                 "initial_stroke_height_px":42.0,"final_stroke_height_px":30.3,
                 "spoken_response":"Your letters shrank by 28% across the line."}
                """.utf8
            )
        ]

        let result = try await makeClient(transport).analyzeHandwriting(
            jpeg: Data([0xFF, 0xD8]),
            sourceContext: .homeMotorExam
        )

        let body = try json(transport.requests.first?.body)
        XCTAssertEqual(transport.requests.first?.url.path, "/api/v1/handwriting/analyze")
        XCTAssertEqual(body["source_context"] as? String, "home_motor_exam")
        XCTAssertNotNil(body["image_base64"])
        XCTAssertTrue(result.measured)
        XCTAssertEqual(result.opencvDecayPct, -27.8)
        XCTAssertTrue(result.micrographiaDetected)
    }

    /// An unreadable photo comes back unmeasured, and the client must say so
    /// rather than invent a decay figure.
    func testUnreadableHandwritingIsReportedAsUnmeasured() async throws {
        let transport = RecordingJSONTransport()
        transport.responses = [
            Data(
                """
                {"event_uuid":"hw-2","measured":false,"opencv_cc_decay_pct":null,
                 "handwriting_score":null,"micrographia_detected":false,
                 "sam_3_1_decay_pct":null,"deskew_angle_deg":0.0,"letter_boxes":[],
                 "initial_stroke_height_px":null,"final_stroke_height_px":null,
                 "spoken_response":"I couldn't read enough of that line to measure it."}
                """.utf8
            )
        ]

        let result = try await makeClient(transport).analyzeHandwriting(jpeg: Data([0x00]))
        XCTAssertFalse(result.measured)
        XCTAssertNil(result.opencvDecayPct)
    }

    func testMealLogSendsOnlyATimestamp() async throws {
        let transport = RecordingJSONTransport()
        transport.responses = [Data(#"{"event_uuid":"meal-1","estimated_protein_grams":null,"plate_detected":false,"items":[],"conflict_detected":false,"spoken_response":"Meal time logged in your routine diary."}"#.utf8)]
        let result = try await makeClient(transport).logMeal(jpeg: Data([0xFF]))
        XCTAssertEqual(transport.requests.first?.url.path, "/api/v1/meals/log")
        let body = try json(transport.requests.first?.body)
        XCTAssertNil(body["image_base64"])
        XCTAssertNotNil(body["timestamp_utc"])
        XCTAssertNil(result.estimatedProteinGrams)
        XCTAssertFalse(result.conflictDetected)
    }

    func testDoseLogPostsATimestampedEvent() async throws {
        let transport = RecordingJSONTransport()
        transport.responses = [Data(#"{"status":"logged","event_uuid":"d-1","event_type":"dose_taken"}"#.utf8)]

        try await makeClient(transport).logDose(medicationName: "Levodopa/Carbidopa")

        let body = try json(transport.requests.first?.body)
        XCTAssertEqual(transport.requests.first?.url.path, "/api/v1/medication/dose")
        XCTAssertEqual(body["medication_name"] as? String, "Levodopa/Carbidopa")
        XCTAssertNotNil(body["event_uuid"])
        XCTAssertNotNil(body["timestamp_utc"])
    }

    func testReportSummaryIsDecoded() async throws {
        let transport = RecordingJSONTransport()
        transport.responses = [
            Data(
                """
                {"patient_id":"default_patient",
                 "summary_stats":{"on_pct":55.0,"wearing_off_pct":20.0,"off_pct":15.0,"no_dose_pct":10.0,
                   "fog_count":2,"fall_count":0,"fall_candidate_resolved_count":1,"fall_suppressed_count":0,
                   "latest_exam_score":76.4,"exam_on_vs_off_delta":null},
                 "buckets_24h":[{"label_hhmm":"08:00","clinical_state":"ON","symptom_burden_score":4.0}],
                 "clinical_narrative":"Objective 24h Motor Summary.",
                 "motor_exams":[],"fog_events":[],"fall_events":[],"medication_logs":[],
                 "reality_checks":[],"handwriting_logs":[]}
                """.utf8
            )
        ]

        let report = try await makeClient(transport).fetchReport()
        XCTAssertEqual(transport.requests.first?.method, "GET")
        XCTAssertEqual(report.summary.onPct, 55.0)
        XCTAssertEqual(report.summary.fogCount, 2)
        XCTAssertEqual(report.summary.latestExamScore, 76.4)
        XCTAssertEqual(report.buckets.first?.clinicalState, "ON")
        XCTAssertEqual(report.clinicalNarrative, "Objective 24h Motor Summary.")
    }

    func testTransportFailuresSurfaceAsErrors() async {
        let transport = RecordingJSONTransport()
        transport.error = URLError(.notConnectedToInternet)

        do {
            _ = try await makeClient(transport).realityCheck(question: "Anyone there?", jpeg: Data([1]))
            XCTFail("an offline transport must throw")
        } catch {
            // expected
        }
    }
}
