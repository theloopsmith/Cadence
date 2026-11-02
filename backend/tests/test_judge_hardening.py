"""Quota, provenance and public contract regressions; no provider requests."""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pytest
from fastapi import HTTPException
from fastapi.testclient import TestClient

from app import auth
from app.config import Settings, settings
from app.main import app
from app.rate_limit import InferenceQuota
from app.responses import ExamHistoryResponse, NeurologistReportResponse, RealityCheckResponse


def headers(token=None):
    return {"Authorization": "Bearer " + (token or settings.cadence_device_token)}


def test_default_database_is_absolute_and_independent_of_working_directory(tmp_path, monkeypatch):
    monkeypatch.delenv("SQLITE_DB_PATH", raising=False)
    expected = Path(__file__).resolve().parents[1] / "cadence_clinical.db"
    first = Settings(_env_file=None).sqlite_db_path
    monkeypatch.chdir(tmp_path)
    assert Settings(_env_file=None).sqlite_db_path == first == str(expected)
    assert Settings(_env_file=None, sqlite_db_path="./cadence_clinical.db").sqlite_db_path == first


def test_source_public_tokens_are_not_runtime_defaults(monkeypatch):
    for name in ("CADENCE_DEVICE_TOKEN", "CADENCE_CLINICIAN_TOKEN", "ALLOW_STATIC_TOKENS"):
        monkeypatch.delenv(name, raising=False)
    clean = Settings(_env_file=None)
    assert clean.cadence_device_token == clean.cadence_clinician_token == ""
    assert not clean.static_tokens_enabled
    monkeypatch.setattr(settings, "cadence_device_token", "")
    monkeypatch.setattr(settings, "cadence_clinician_token", "")
    with TestClient(app) as http:
        for token in ("cadence-dev-device-writer-token-2026", "cadence-dev-clinician-reader-token-2026"):
            assert http.get("/api/v1/device/connection", headers=headers(token)).status_code == 401




def test_quota_is_atomic_and_expires_without_sleep():
    now = [100.0]
    quota = InferenceQuota(clock=lambda: now[0])
    def consume(_):
        try:
            quota.consume("same-token-hash", 30)
            return True
        except HTTPException as error:
            assert error.status_code == 429 and error.headers["Retry-After"] == "60"
            return False
    with ThreadPoolExecutor(max_workers=12) as pool:
        assert sum(pool.map(consume, range(60))) == 30
    quota.consume("another-token-hash", 30)
    now[0] += 60
    quota.consume("same-token-hash", 30)
    assert len(quota._windows["same-token-hash"]) == 1


def test_quota_memory_is_bounded_and_inactive_keys_are_evicted():
    now = [0.0]
    quota = InferenceQuota(clock=lambda: now[0], max_keys=1)
    quota.consume("one", 30)
    with pytest.raises(HTTPException) as error:
        quota.consume("two", 30)
    assert error.value.status_code == 429
    now[0] = 60
    quota.consume("two", 30)
    assert set(quota._windows) == {"two"}


def test_paid_routes_share_quota_and_unauthorized_requests_do_not_consume(monkeypatch):
    monkeypatch.setattr(settings, "inference_requests_per_minute", 1)
    calls = []
    async def interpret(*args):
        calls.append(args)
        return {"intent": "unknown"}
    monkeypatch.setattr("app.services.companion.interpret", interpret)
    with TestClient(app) as http:
        assert http.post("/api/v1/companion/interpret", json={"text": "hello"}).status_code == 401
        assert http.post("/api/v1/companion/interpret", headers=headers(), json={"text": "hello"}).status_code == 200
        for path, body in [
            ("/api/v1/companion/interpret", {"text": "hello"}),
            ("/api/v1/reality-check", {"event_uuid": "quota-photo", "user_query": "chair?"}),
            ("/api/v1/handwriting/analyze", {"event_uuid": "quota-writing"}),
            ("/api/v1/speech/transcribe", {"audio_base64": "AAAA", "purpose": "companion"}),
        ]:
            result = http.post(path, headers=headers(), json=body)
            assert result.status_code == 429, (path, result.text)
            assert result.headers["Retry-After"] == "60"
        # Ordinary ingestion/reporting and urgent fall-check-in transcription remain available.
        assert http.post("/api/v1/medication/dose", headers=headers(), json={"event_uuid": "quota-dose"}).status_code == 200
        assert http.get("/api/v1/report/neurologist", headers=headers()).status_code == 200
        for _ in range(60):
            assert http.post("/api/v1/speech/transcribe", headers=headers(), json={"audio_base64": "AAAA", "purpose": "fall_check_in"}).status_code == 400
        assert http.post("/api/v1/speech/transcribe", headers=headers(), json={"audio_base64": "AAAA", "purpose": "fall_check_in"}).status_code == 429
        another = auth.issue_token("other-phone", "device_writer", "other-wearer")
        assert http.post("/api/v1/companion/interpret", headers=headers(another), json={"text": "hello"}).status_code == 200
        rotated = auth.issue_token("other-phone", "device_writer", "other-wearer", ttl_seconds=100)
        assert http.post("/api/v1/companion/interpret", headers=headers(rotated), json={"text": "hello"}).status_code == 429
    assert len(calls) == 2


def test_judge_paths_keep_explicit_response_contracts_and_sample_provenance():
    contracts = {"/api/v1/report/neurologist": NeurologistReportResponse,
                 "/api/v1/exam/history": ExamHistoryResponse,
                 "/api/v1/reality-check": RealityCheckResponse}
    for path, model in contracts.items():
        route = next(route for route in app.routes if route.path == path)
        assert route.response_model is not None
        assert model.__name__ in str(route.response_model)
        assert route.response_model_exclude_unset is True
    with TestClient(app) as http:
        assert http.post("/api/v1/demo/seed", headers=headers()).status_code == 200
        report = http.get("/api/v1/report/neurologist", headers=headers()).json()
        history = http.get("/api/v1/exam/history", headers=headers()).json()
    for row in report["motor_exams"] + history["exams"]:
        assert row["measurement_source"] == "simulated"
        assert "simulated sample" in row["clinical_summary"]
        for task in ("voice", "handwriting", "walk"):
            assert row["task_evidence"][task] == {"status": row[task + "_status"], "measurement_source": "simulated"}
    assert report["summary_stats"]["latest_exam_metrics"]["measurement_source"] == "simulated"
    assert "Latest motor check (simulated sample)" in report["clinical_narrative"]
    # Check all nested seeded legacy records, not just empty-report defaults.
    banned = {"clinical_state", "medication_state_label", "symptom_burden_score", "voice_score",
              "handwriting_score", "gait_score", "composite_motor_score", "exam_composite_score",
              "on_pct", "off_pct", "wearing_off_pct", "estimated_protein_grams", "conflict_detected",
              "protein_conflict_active", "micrographia_detected"}
    def inspect(value):
        if isinstance(value, dict):
            assert not (banned & value.keys())
            for nested in value.values():
                inspect(nested)
        elif isinstance(value, list):
            for nested in value:
                inspect(nested)
    inspect(report)
    inspect(history)
    # Defense in depth: even an endpoint accidentally returning raw legacy values
    # must not expose them through nested free-form report record collections.
    report["medication_logs"] = [{"event_type": "meal_logged", "nested": {key: 99 for key in banned}}]
    report["motor_exams"][0]["future_unreviewed_score"] = 100
    projected = NeurologistReportResponse.model_validate(report).model_dump(exclude_unset=True)
    inspect(projected)
    assert "future_unreviewed_score" not in projected["motor_exams"][0]
    incomplete = dict(history); incomplete["exams"] = [dict(history["exams"][0])]
    incomplete["exams"][0].pop("measurement_source")
    from pydantic import ValidationError
    with pytest.raises(ValidationError):
        ExamHistoryResponse.model_validate(incomplete)
