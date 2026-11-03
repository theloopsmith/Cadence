import base64
from pathlib import Path
from unittest.mock import AsyncMock

import pytest
from fastapi.testclient import TestClient

from app.config import settings
from app.db import fetch_all, init_db_sync
from app.main import app
from app.services.handwriting import analyze_handwriting_opencv


def test_method_invariant_handwriting_opencv_score():
    # 35% shrinkage (-35.0%) -> score = 52.0 regardless of sam_3_1_decay_pct
    r_with_sam = analyze_handwriting_opencv(
        image_bytes=None,
        simulated_letter_heights_px=[100.0, 100.0, 100.0, 65.0, 65.0, 65.0],
        simulated_sam_decay_pct=-42.0,
    )
    r_without_sam = analyze_handwriting_opencv(
        image_bytes=None,
        simulated_letter_heights_px=[100.0, 100.0, 100.0, 65.0, 65.0, 65.0],
        simulated_sam_decay_pct=None,
    )
    assert r_with_sam["opencv_cc_decay_pct"] == -35.0
    assert "handwriting_score" not in r_with_sam
    assert "handwriting_score" not in r_without_sam
    assert "micrographia_detected" not in r_with_sam


def test_too_few_letters_is_not_scored_as_healthy_writing():
    """Three strokes cannot show progressive shrinkage. Scoring them 100 made
    a failed photo look like normal handwriting on the report."""
    res = analyze_handwriting_opencv(
        image_bytes=None,
        simulated_letter_heights_px=[40.0, 20.0, 10.0],
    )
    assert res["measured"] is False
    assert "handwriting_score" not in res
    assert res["opencv_cc_decay_pct"] is None


def test_a_missing_or_undecodable_photo_is_not_scored_as_healthy_writing():
    missing = analyze_handwriting_opencv(image_bytes=None)
    garbage = analyze_handwriting_opencv(image_bytes=b"not-a-jpeg")
    assert missing["measured"] is False
    assert "handwriting_score" not in missing
    assert garbage["measured"] is False
    assert "handwriting_score" not in garbage


@pytest.fixture
def client(monkeypatch, tmp_path):
    monkeypatch.setattr(settings, "sqlite_db_path", str(tmp_path / "writing.db"))
    init_db_sync()
    with TestClient(app) as http:
        yield http


def test_an_unreadable_line_is_not_stored_or_called_steady(client):
    response = client.post(
        "/api/v1/handwriting/analyze",
        headers={"Authorization": f"Bearer {settings.cadence_device_token}"},
        json={
            "event_uuid": "write-unreadable-001",
            "simulated_letter_heights_px": [40.0, 18.0],
        },
    )
    assert response.status_code == 200
    body = response.json()
    assert body["measured"] is False
    assert "steady" not in body["spoken_response"].lower()

    import asyncio

    rows = asyncio.run(
        fetch_all("SELECT event_uuid FROM handwriting_logs WHERE event_uuid = ?", ("write-unreadable-001",))
    )
    assert rows == []


@pytest.mark.parametrize("heights,measured,description", [
    ([40,40,40,32,32,32], True, "20% smaller"),
    ([40,40,40,48,48,48], True, "20% larger"),
    ([40,18], False, "couldn't read enough"),
])
def test_default_handwriting_contract_withholds_research_fields(client, monkeypatch, heights, measured, description):
    response = client.post("/api/v1/handwriting/analyze", headers={"Authorization": f"Bearer {settings.cadence_device_token}"},
        json={"event_uuid":"default-contract", "simulated_letter_heights_px":heights})
    assert response.status_code == 200
    body = response.json()
    assert body["measured"] is measured
    assert description in body["spoken_response"]
    assert "handwriting_score" not in body
    assert "micrographia_detected" not in body
    assert body["opencv_cc_decay_pct"] == (None if not measured else -20 if heights[-1] == 32 else 20)


def test_default_measurement_does_not_compute_a_research_finding():
    from app.services.handwriting import compute_decay_from_heights, handwriting_response
    measured = compute_decay_from_heights([40,40,40,20,20,20])
    assert measured["opencv_cc_decay_pct"] == -50
    assert "handwriting_score" not in measured
    public = handwriting_response({**measured,"future_private_finding":"hidden"})
    assert "micrographia_detected" not in public
    assert "future_private_finding" not in public


def test_default_real_image_input_is_allowed_without_demo_fields(client, monkeypatch):
    import base64
    import cv2
    import numpy as np
    monkeypatch.setattr(settings, "demo_mode", False)
    ok, image = cv2.imencode(".png", np.full((64,64),255,dtype=np.uint8))
    assert ok
    response = client.post("/api/v1/handwriting/analyze", headers={"Authorization": f"Bearer {settings.cadence_device_token}"},
        json={"event_uuid":"blank-image-contract", "image_base64":base64.b64encode(image).decode()})
    assert response.status_code == 200
    assert response.json()["measured"] is False
    assert "micrographia_detected" not in response.json()

def test_handwriting_quality_is_opt_in_and_preview_does_not_save(client, monkeypatch):
    from app.clients.baseten_llm import baseten_client

    photo = Path(__file__).resolve().parents[1] / "app/static/walkthrough/handwriting-capture.jpg"
    review = AsyncMock(return_value={"labels": ["multiple_lines"], "model": "test-muse", "provider": "baseten"})
    monkeypatch.setattr(baseten_client, "check_handwriting_photo", review)
    headers = {"Authorization": f"Bearer {settings.cadence_device_token}"}
    payload = {"event_uuid": "writing-photo-preview", "image_base64": base64.b64encode(photo.read_bytes()).decode(),
               "preview_only": True}

    standard = client.post("/api/v1/handwriting/analyze", headers=headers, json=payload)
    assert standard.status_code == 200
    assert standard.json()["measured"] is True
    assert "photo_quality" not in standard.json()
    review.assert_not_awaited()

    reviewed = client.post("/api/v1/handwriting/analyze", headers=headers, json={**payload, "check_photo_quality": True})
    assert reviewed.status_code == 200
    assert reviewed.json()["photo_quality"]["advice"] == "Frame just the single line you wrote."
    assert reviewed.json()["opencv_cc_decay_pct"] == standard.json()["opencv_cc_decay_pct"]
    review.assert_awaited_once()
    assert client.get("/api/v1/report/neurologist", headers=headers).json()["handwriting_logs"] == []
