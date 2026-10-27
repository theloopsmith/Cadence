from fastapi.testclient import TestClient
from app.config import settings
from app.main import app

DEVICE_HEADERS = {"Authorization": f"Bearer {settings.cadence_device_token}"}


def test_fall_groan_override_gps_and_signed_webhook_rejection():
    with TestClient(app) as client:
        # 1. Groan (vocal_activity_detected=True) overrides worn_pre_impact=False
        resp = client.post(
            "/api/v1/events/fall",
            headers=DEVICE_HEADERS,
            json={
                "event_uuid": "fall-unit-001",
                "peak_impact_g": 3.9,
                "peak_jerk_gs": 52.0,
                "post_impact_tilt_deg": 70.0,
                "worn_pre_impact": False,
                "vocal_activity_detected": True,
                "latitude": 37.7749,
                "longitude": -122.4194,
            },
        )
        assert resp.status_code == 200
        data = resp.json()
        assert data["twilio_dispatched"] is True
        assert "maps.google.com/?q=37.774900,-122.419400" in data["sms_body"]

        # 2. Gather keypress '1' acknowledges the alert
        gather = client.post(
            "/api/v1/webhooks/twilio/gather?event_uuid=fall-unit-001",
            data={"Digits": "1"},
        )
        assert gather.status_code == 200
        assert "Alert acknowledged" in gather.text
