import os
import tempfile
import time
import pytest
from fastapi.testclient import TestClient

# Point SQLite to a temporary file before importing app
_tmp_db = tempfile.NamedTemporaryFile(suffix=".db", delete=False)
_tmp_db.close()
os.environ["SQLITE_DB_PATH"] = _tmp_db.name

from app.clients.circuit_breaker import PerModelCircuitBreakerRegistry, RequestDeadlineContext
from app.config import settings
from app.db import init_db_sync, fetch_one_sync
from app.main import app
from app.services.handwriting import compute_decay_from_heights

init_db_sync()

DEVICE_HEADERS = {"Authorization": f"Bearer {settings.cadence_device_token}"}
CLINICIAN_HEADERS = {"Authorization": f"Bearer {settings.cadence_clinician_token}"}






def test_per_model_circuit_breaker_isolation():
    """Verifies that 3 failures on ('meta', 'sam-3.1') never trip ('meta', 'muse-voice-transcribe-1.0')."""
    reg = PerModelCircuitBreakerRegistry(failure_threshold=3, cooldown_sec=60.0)
    for _ in range(3):
        reg.record_failure("meta", "sam-3.1")
    assert not reg.is_available("meta", "sam-3.1")
    assert reg.is_available("meta", "muse-voice-transcribe-1.0")




def test_end_to_end_api_pipelines_and_rbac():
    device_headers = dict(DEVICE_HEADERS)
    with TestClient(app) as client:
        # 1. Public health & dashboard HTML shell
        assert client.get("/health").status_code == 200
        dash = client.get("/dashboard")
        assert dash.status_code == 200
        assert "sessionStorage" in dash.text

        # 2. Clinician token cannot POST or DELETE (403 Forbidden)
        forbidden_post = client.post(
            "/api/v1/events/fog",
            headers=CLINICIAN_HEADERS,
            json={
                "event_uuid": "fog-test-001",
                "duration_sec": 4.2,
                "peak_freeze_index": 3.4,
                "locomotor_band_power": 0.05,
                "freeze_band_power": 0.17,
                "sampled_hz": 50.0,
                "arming_mode": "turning_upright",
            },
        )
        assert forbidden_post.status_code == 403
        assert client.delete("/api/v1/patient/data", headers=CLINICIAN_HEADERS).status_code == 403
        wiped = client.delete("/api/v1/patient/data", headers=device_headers)
        assert wiped.status_code == 200
        device_headers["X-Cadence-Data-Generation"] = str(wiped.json()["data_generation"])

        # 3. Device token logs FoG, Dose, Meal Protein, Reality Check, Handwriting, Fall & Exam
        fog_ok = client.post(
            "/api/v1/events/fog",
            headers=device_headers,
            json={
                "event_uuid": "fog-test-001",
                "duration_sec": 4.2,
                "peak_freeze_index": 3.4,
                "locomotor_band_power": 0.05,
                "freeze_band_power": 0.17,
                "sampled_hz": 50.0,
                "arming_mode": "turning_upright",
            },
        )
        assert fog_ok.status_code == 200

        # Reality Check: SAM detects coat on chair (no person) -> grounded to 'coat'
        rc_ok = client.post(
            "/api/v1/reality-check",
            headers=device_headers,
            json={
                "event_uuid": "rc-test-001",
                "user_query": "Is someone sitting in that chair?",
                "simulated_sam_masks": [
                    {"label": "coat", "confidence": 0.91, "area_ratio": 0.08},
                    {"label": "chair", "confidence": 0.85, "area_ratio": 0.15},
                ],
            },
        )
        assert rc_ok.status_code == 200
        rc_data = rc_ok.json()
        assert rc_data["living_subject_present"] is False
        assert rc_data["chosen_inanimate_label"] == "coat"
        assert "coat" in rc_data["spoken_response"]

        # Fall Event with GPS & Post-Dispatch Cancel -> All-Clear SMS
        fall_ok = client.post(
            "/api/v1/events/fall",
            headers=device_headers,
            json={
                "event_uuid": "fall-test-001",
                "peak_impact_g": 3.6,
                "peak_jerk_gs": 48.0,
                "post_impact_tilt_deg": 68.0,
                "worn_pre_impact": False,
                "vocal_activity_detected": True,  # Groan overrides worn_pre_impact=False!
                "latitude": 37.7749,
                "longitude": -122.4194,
            },
        )
        assert fall_ok.status_code == 200
        fall_data = fall_ok.json()
        assert fall_data["twilio_dispatched"] is True
        assert "https://maps.google.com/?q=37.774900,-122.419400" in fall_data["sms_body"]

        cancel_ok = client.post(
            "/api/v1/events/fall/fall-test-001/cancel",
            headers=device_headers,
        )
        assert cancel_ok.status_code == 200
        assert cancel_ok.json()["status"] == "canceled_false_alarm"
        # A recovery worker may own the clear-job lease before cancel returns.
        # Observe the durable outcome rather than require this request to send it.
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            clear = fetch_one_sync("SELECT COUNT(*) AS cnt FROM caregiver_alerts WHERE fall_event_uuid=? AND channel='all_clear_sms'", ("fall-test-001",))
            if clear["cnt"] >= 1: break
            time.sleep(.01)
        assert clear["cnt"] >= 1

        # Guided Home Motor Exam
        exam_ok = client.post(
            "/api/v1/exam/complete",
            headers=device_headers,
            json={
                "exam_uuid": "exam-test-001",
            "voice_status": "measured", "handwriting_status": "measured", "walk_status": "measured", "measurement_source": "device",
                "voice_mean_dbfs": -28.0,
                "voice_stability_db": 3.5,
                "handwriting_opencv_decay_pct": -35.0,
                "handwriting_sam_decay_pct": -36.0,
                "walk_cadence_spm": 85.0,
                "walk_mean_fi": 2.2,
                "walk_fog_count": 1,
            },
        )
        assert exam_ok.status_code == 200
        assert "composite_motor_score" not in exam_ok.json()

        # Clinician reader fetches report
        rep = client.get("/api/v1/report/neurologist", headers=CLINICIAN_HEADERS)
        assert rep.status_code == 200
        assert len(rep.json()["motor_exams"]) == 1
