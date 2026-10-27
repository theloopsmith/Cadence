from fastapi.testclient import TestClient
from app.config import settings
from app.main import app

DEVICE_HEADERS = {"Authorization": f"Bearer {settings.cadence_device_token}"}


def test_reality_check_l_sam_locked_slot_and_unverified_fallback():
    with TestClient(app) as client:
        # 1. L_sam has pillow + armchair -> chosen_inanimate_label must be in L_sam
        r1 = client.post(
            "/api/v1/reality-check",
            headers=DEVICE_HEADERS,
            json={
                "event_uuid": "rc-unit-001",
                "user_query": "Is someone sitting on the sofa?",
                "simulated_sam_masks": [
                    {"label": "pillow", "confidence": 0.90, "area_ratio": 0.05},
                    {"label": "sofa", "confidence": 0.88, "area_ratio": 0.25},
                ],
            },
        )
        assert r1.status_code == 200
        d1 = r1.json()
        assert d1["living_subject_present"] is False
        assert d1["chosen_inanimate_label"] in {"pillow", "sofa"}

        # 2. When SAM 3.1 is unverified (no image & no simulated masks), returns lighting fallback
        r2 = client.post(
            "/api/v1/reality-check",
            headers=DEVICE_HEADERS,
            json={
                "event_uuid": "rc-unit-002",
                "user_query": "Is someone standing by the door?",
            },
        )
        assert r2.status_code == 200
        assert r2.json()["template_id"] == "UNVERIFIED_LIGHTING_FALLBACK"
