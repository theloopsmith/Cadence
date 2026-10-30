import pytest
from datetime import datetime, timedelta, timezone
from fastapi.testclient import TestClient

from app.config import settings
from app.db import init_db_sync, _connect_sync, execute_write_sync
from app.main import app

DEVICE_HEADERS = {"Authorization": f"Bearer {settings.cadence_device_token}"}
CLINICIAN_HEADERS = {"Authorization": f"Bearer {settings.cadence_clinician_token}"}


@pytest.fixture(autouse=True)
def setup_isolated_db(tmp_path, monkeypatch):
    test_db = str(tmp_path / "test_retraction_wipe.db")
    monkeypatch.setattr(settings, "sqlite_db_path", test_db)
    init_db_sync(test_db)
    yield


def test_dose_retraction_normal_order():
    with TestClient(app) as client:
        now = datetime.now(timezone.utc)
        dose_time = now.isoformat()
        retract_time = (now + timedelta(seconds=10)).isoformat()

        # 1. Log a dose
        dose_res = client.post(
            "/api/v1/medication/dose",
            headers=DEVICE_HEADERS,
            json={
                "event_uuid": "dose-evt-001",
                "timestamp_utc": dose_time,
                "medication_name": "Levodopa 100mg",
            },
        )
        assert dose_res.status_code == 200
        assert dose_res.json()["status"] == "logged"

        # Verify it appears in neurologist report
        rep1 = client.get("/api/v1/report/neurologist", headers=DEVICE_HEADERS).json()
        assert any(m["event_uuid"] == "dose-evt-001" for m in rep1["medication_logs"])
        assert rep1["summary_stats"]["dose_count"] == 1

        # 2. Retract the dose (Undo)
        retract_res = client.post(
            "/api/v1/medication/dose/retract",
            headers=DEVICE_HEADERS,
            json={
                "event_uuid": "retract-evt-001",
                "retracted_event_uuid": "dose-evt-001",
                "timestamp_utc": retract_time,
                "reason": "user_undo",
            },
        )
        assert retract_res.status_code == 200
        assert retract_res.json()["status"] == "retracted"
        assert retract_res.json()["retracted_event_uuid"] == "dose-evt-001"

        # Verify it is now excluded from the neurologist report and summary stats
        rep2 = client.get("/api/v1/report/neurologist", headers=DEVICE_HEADERS).json()
        assert not any(m["event_uuid"] == "dose-evt-001" for m in rep2["medication_logs"])
        assert rep2["summary_stats"]["dose_count"] == 0


def test_dose_retraction_out_of_order_arrival():
    """If the retraction arrives before the dose (due to network reordering/retries),
    the dose must be recognized as already retracted and ignored."""
    with TestClient(app) as client:
        now = datetime.now(timezone.utc)
        retract_time = (now + timedelta(seconds=5)).isoformat()
        dose_time = now.isoformat()

        # 1. Retraction arrives FIRST
        retract_res = client.post(
            "/api/v1/medication/dose/retract",
            headers=DEVICE_HEADERS,
            json={
                "event_uuid": "retract-evt-early",
                "retracted_event_uuid": "dose-evt-delayed",
                "timestamp_utc": retract_time,
                "reason": "user_undo",
            },
        )
        assert retract_res.status_code == 200
        assert retract_res.json()["status"] == "retracted"

        # 2. Delayed dose arrives LATER
        dose_res = client.post(
            "/api/v1/medication/dose",
            headers=DEVICE_HEADERS,
            json={
                "event_uuid": "dose-evt-delayed",
                "timestamp_utc": dose_time,
                "medication_name": "Levodopa 100mg",
            },
        )
        assert dose_res.status_code == 200
        assert dose_res.json()["status"] == "retracted_ignored"

        # Verify it is NOT in the neurologist report
        rep = client.get("/api/v1/report/neurologist", headers=DEVICE_HEADERS).json()
        assert not any(m["event_uuid"] == "dose-evt-delayed" for m in rep["medication_logs"])
        assert rep["summary_stats"]["dose_count"] == 0


def test_dose_retraction_idempotence():
    with TestClient(app) as client:
        now = datetime.now(timezone.utc).isoformat()
        payload = {
            "event_uuid": "retract-evt-idem",
            "retracted_event_uuid": "dose-evt-target",
            "timestamp_utc": now,
            "reason": "user_undo",
        }
        res1 = client.post("/api/v1/medication/dose/retract", headers=DEVICE_HEADERS, json=payload)
        assert res1.status_code == 200
        assert res1.json()["status"] == "retracted"

        # Duplicate post with same UUID
        res2 = client.post("/api/v1/medication/dose/retract", headers=DEVICE_HEADERS, json=payload)
        assert res2.status_code == 200
        assert res2.json()["status"] == "retracted"


def test_server_wipe_offline_upload_coordination():
    """Events queued while offline that predate a server wipe must be dropped cleanly."""
    with TestClient(app) as client:
        # 1. Log an event prior to wipe
        t0 = (datetime.now(timezone.utc) - timedelta(minutes=10)).isoformat()
        client.post(
            "/api/v1/events/fog",
            headers=DEVICE_HEADERS,
            json={
                "event_uuid": "pre-wipe-fog",
                "timestamp_utc": t0,
                "duration_sec": 4.0,
                "peak_freeze_index": 2.5,
                "locomotor_band_power": 0.1,
                "freeze_band_power": 0.25,
                "sampled_hz": 50.0,
                "arming_mode": "sit_to_stand",
                "speech_active_modifier": False,
                "cue_bpm": 100,
                "recovery_latency_sec": 4.0,
            },
        )

        # 2. Perform a patient data wipe
        wipe_res = client.delete("/api/v1/patient/data", headers=DEVICE_HEADERS)
        assert wipe_res.status_code == 200
        wipe_data = wipe_res.json()
        assert wipe_data["status"] == "wiped"
        wiped_at = wipe_data["wiped_at_utc"]
        assert wiped_at is not None

        # 3. Verify connection endpoint reports latest wipe
        conn_res = client.get(
            "/api/v1/device/connection?include_wipe_status=true",
            headers=DEVICE_HEADERS,
        )
        assert conn_res.status_code == 200
        assert conn_res.json()["latest_wipe_utc"] == wiped_at

        # 4. An offline client now attempts to upload a pre-wipe event
        offline_event_time = (datetime.now(timezone.utc) - timedelta(minutes=5)).isoformat()
        offline_res = client.post(
            "/api/v1/events/fog",
            headers=DEVICE_HEADERS,
            json={
                "event_uuid": "offline-old-fog",
                "timestamp_utc": offline_event_time,
                "duration_sec": 3.0,
                "peak_freeze_index": 2.2,
                "locomotor_band_power": 0.1,
                "freeze_band_power": 0.2,
                "sampled_hz": 50.0,
                "arming_mode": "sit_to_stand",
                "speech_active_modifier": False,
                "cue_bpm": 100,
                "recovery_latency_sec": 3.0,
            },
        )
        # Must return 200 OK so the client queue marks it synced/dropped and doesn't retry forever,
        # but with status 'dropped_wiped'
        assert offline_res.status_code == 200
        assert offline_res.json()["status"] == "dropped_wiped"

        # 5. A fresh post-wipe event is accepted normally
        import time
        time.sleep(0.05)
        fresh_event_time = datetime.now(timezone.utc).isoformat()
        fresh_res = client.post(
            "/api/v1/events/fog",
            headers=DEVICE_HEADERS,
            json={
                "event_uuid": "fresh-fog-001",
                "timestamp_utc": fresh_event_time,
                "duration_sec": 3.0,
                "peak_freeze_index": 2.2,
                "locomotor_band_power": 0.1,
                "freeze_band_power": 0.2,
                "sampled_hz": 50.0,
                "arming_mode": "sit_to_stand",
                "speech_active_modifier": False,
                "cue_bpm": 100,
                "recovery_latency_sec": 3.0,
            },
        )
        assert fresh_res.status_code == 200
        assert fresh_res.json()["status"] == "logged"

        time.sleep(0.05)
        # Neurologist report only contains the fresh event, not the pre-wipe ones
        rep = client.get("/api/v1/report/neurologist", headers=DEVICE_HEADERS).json()
        assert len(rep["fog_events"]) == 1
        assert rep["fog_events"][0]["event_uuid"] == "fresh-fog-001"
