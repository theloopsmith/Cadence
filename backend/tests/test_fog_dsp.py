from fastapi.testclient import TestClient
from app.config import settings
from app.main import app

DEVICE_HEADERS = {"Authorization": f"Bearer {settings.cadence_device_token}"}


def test_fog_event_ingestion_and_idempotency():
    with TestClient(app) as client:
        payload = {
            "event_uuid": "fog-dsp-unit-001",
            "duration_sec": 3.8,
            "peak_freeze_index": 3.2,
            "locomotor_band_power": 0.04,
            "freeze_band_power": 0.13,
            "sampled_hz": 50.0,
            "arming_mode": "turning_upright",
            "speech_active_modifier": True,
            "cue_bpm": 100,
        }
        r1 = client.post("/api/v1/events/fog", headers=DEVICE_HEADERS, json=payload)
        r2 = client.post("/api/v1/events/fog", headers=DEVICE_HEADERS, json=payload)
        assert r1.status_code == 200
        assert r2.status_code == 200
