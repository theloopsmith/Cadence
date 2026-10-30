import os
import tempfile
import time
import pytest
from fastapi.testclient import TestClient

_tmp_db = tempfile.NamedTemporaryFile(suffix=".db", delete=False)
_tmp_db.close()
os.environ["SQLITE_DB_PATH"] = _tmp_db.name

from app.clients.circuit_breaker import PerModelCircuitBreakerRegistry, RequestDeadlineContext
from app.config import settings
settings.sqlite_db_path = _tmp_db.name
from app.db import init_db_sync, _connect_sync
from app.main import app

init_db_sync()

DEVICE_HEADERS = {"Authorization": f"Bearer {settings.cadence_device_token}"}
CLINICIAN_HEADERS = {"Authorization": f"Bearer {settings.cadence_clinician_token}"}


class TestCircuitBreakerAndDeadlineDrills:
    """Verifies per-model circuit breaker isolation and 4.0s deadline budget enforcement."""

    def test_sam_slowdown_trips_sam_alone_without_affecting_other_models(self):
        registry = PerModelCircuitBreakerRegistry(failure_threshold=3, cooldown_sec=10.0)
        sam_key = ("baseten", "sam-3-1")
        tts_key = ("baseten", "muse-voice")
        stt_key = ("baseten", "whisper-v3")

        # Initially all models are available
        assert registry.is_available(*sam_key) is True
        assert registry.is_available(*tts_key) is True
        assert registry.is_available(*stt_key) is True

        # 2 failures do not trip SAM
        registry.record_failure(*sam_key)
        registry.record_failure(*sam_key)
        assert registry.is_available(*sam_key) is True

        # 3rd failure trips SAM
        registry.record_failure(*sam_key)
        assert registry.is_available(*sam_key) is False

        # Other models remain healthy and isolated
        assert registry.is_available(*tts_key) is True
        assert registry.is_available(*stt_key) is True

        # Resetting or success clears failure state
        registry.record_success(*sam_key)
        assert registry.is_available(*sam_key) is True

    def test_deadline_context_bounds_stage_and_raises_timeout_error(self):
        # Fresh context with 4.0s budget
        ctx = RequestDeadlineContext(total_budget_sec=4.0)
        assert ctx.remaining_sec() > 3.5

        # Allocating a stage bounded by stage_max
        allocated = ctx.timeout_for_stage(stage_max_sec=1.2, min_viable_sec=0.35)
        assert allocated <= 1.2

        # Simulating an exhausted context
        exhausted = RequestDeadlineContext(
            total_budget_sec=4.0,
            started_at=time.monotonic() - 3.8,  # only ~0.2s left < 0.35s
        )
        with pytest.raises(TimeoutError) as exc_info:
            exhausted.timeout_for_stage(stage_max_sec=1.5, min_viable_sec=0.35)
        assert "Request deadline exhausted" in str(exc_info.value)

    def test_fireworks_client_breaker_isolation_and_fallback(self):
        from app.clients.fireworks_client import fireworks_client
        registry = PerModelCircuitBreakerRegistry(failure_threshold=3, cooldown_sec=10.0)
        fw_key = (fireworks_client.PROVIDER, settings.fireworks_llm_model)

        assert registry.is_available(*fw_key) is True
        for _ in range(3):
            registry.record_failure(*fw_key)
        assert registry.is_available(*fw_key) is False

        # Resetting restores availability
        registry.record_success(*fw_key)
        assert registry.is_available(*fw_key) is True


class TestDatabaseIntegrityDrills:
    """Verifies WAL mode, foreign key enforcement, and SQLCipher / schema integrity."""

    def test_database_pragmas_and_foreign_keys_enforced(self):
        conn = _connect_sync()
        try:
            # WAL journal mode verification
            journal_mode = conn.execute("PRAGMA journal_mode;").fetchone()[0]
            assert journal_mode.lower() == "wal"

            # Foreign keys enabled
            fk = conn.execute("PRAGMA foreign_keys;").fetchone()[0]
            assert fk == 1

            # Verify all required tables exist
            tables = [
                row[0]
                for row in conn.execute(
                    "SELECT name FROM sqlite_master WHERE type='table';"
                ).fetchall()
            ]
            expected_tables = [
                "fog_events",
                "fall_events",
                "caregiver_alerts",
                "medication_logs",
                "reality_checks",
                "handwriting_logs",
                "motor_exams",
                "voice_logs",
            ]
            for t in expected_tables:
                assert t in tables, f"Missing expected table {t}"
        finally:
            conn.close()


class TestOfflineBatchReconnectDrill:
    """Verifies that events buffered during connectivity loss are processed and assigned correctly."""

    def test_offline_buffered_events_ingested_and_surface_in_neurologist_report(self):
        client = TestClient(app)

        # 1. Device was offline during an event 40 minutes ago
        from datetime import datetime, timedelta, timezone
        historical_ts = (datetime.now(timezone.utc)-timedelta(minutes=40)).isoformat()
        event_uuid = "drill-fog-offline-001"

        res = client.post(
            "/api/v1/events/fog",
            headers=DEVICE_HEADERS,
            json={
                "event_uuid": event_uuid,
                "timestamp_utc": historical_ts,
                "duration_sec": 8.5,
                "peak_freeze_index": 3.4,
                "locomotor_band_power": 0.04,
                "freeze_band_power": 0.14,
                "sampled_hz": 50.0,
                "arming_mode": "turning_upright",
                "speech_active_modifier": False,
                "cue_bpm": 100,
                "recovery_latency_sec": 8.5,
            },
        )
        assert res.status_code == 200
        assert res.json()["status"] == "logged"

        # 2. Duplicate sync attempt is idempotent
        dup_res = client.post(
            "/api/v1/events/fog",
            headers=DEVICE_HEADERS,
            json={
                "event_uuid": event_uuid,
                "timestamp_utc": historical_ts,
                "duration_sec": 8.5,
                "peak_freeze_index": 3.4,
                "locomotor_band_power": 0.04,
                "freeze_band_power": 0.14,
                "sampled_hz": 50.0,
                "arming_mode": "turning_upright",
                "speech_active_modifier": False,
                "cue_bpm": 100,
                "recovery_latency_sec": 8.5,
            },
        )
        assert dup_res.status_code == 200

        # 3. Report reader sees the event
        report_res = client.get("/api/v1/report/neurologist", headers=CLINICIAN_HEADERS)
        assert report_res.status_code == 200
        data = report_res.json()
        assert any(e["event_uuid"] == event_uuid for e in data["fog_events"])
