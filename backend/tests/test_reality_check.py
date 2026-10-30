import asyncio

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


def test_a_person_without_a_confidence_value_is_still_a_person():
    """SAM 3.1 may omit `c`. Missing confidence is not zero and must not hide someone."""
    from app.services.reality_check import run_reality_check_pipeline

    result = asyncio.run(
        run_reality_check_pipeline(
            user_query="Is anyone there?",
            image_bytes=None,
            simulated_sam_masks=[{"label": "person", "area_ratio": 0.12}],
        )
    )
    assert result["living_subject_present"] is True
    assert result["template_id"] == "CONFIRM_LIVING_SUBJECT"


def test_low_confidence_is_still_filtered_when_present():
    from app.services.reality_check import run_reality_check_pipeline

    result = asyncio.run(
        run_reality_check_pipeline(
            user_query="Is anyone there?",
            image_bytes=None,
            simulated_sam_masks=[{"label": "person", "confidence": 0.2, "area_ratio": 0.12}],
        )
    )
    assert result["living_subject_present"] is False


def test_concepts_per_photo_are_few_and_always_ask_about_people():
    from app.services.reality_check import reality_check_concepts, LIVING_VOCAB

    concepts = reality_check_concepts("Is someone sitting in the armchair under the coat?")
    assert len(concepts) <= 6
    assert "person" in concepts
    assert any(c in LIVING_VOCAB and c != "person" for c in concepts)
    assert "armchair" in concepts and "coat" in concepts

    plain = reality_check_concepts("Is anyone there?")
    assert "person" in plain
    assert len(plain) <= 6
    # The wearer's question names no object, so a couple of common ones are asked about anyway.
    assert any(c not in LIVING_VOCAB for c in plain)
