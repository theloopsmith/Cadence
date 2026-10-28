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
    assert r_with_sam["handwriting_score"] == 52.0
    assert r_without_sam["handwriting_score"] == 52.0
    assert r_with_sam["micrographia_detected"] is True


def test_too_few_letters_is_not_scored_as_healthy_writing():
    """Three strokes cannot show progressive shrinkage. Scoring them 100 made
    a failed photo look like normal handwriting on the report."""
    res = analyze_handwriting_opencv(
        image_bytes=None,
        simulated_letter_heights_px=[40.0, 20.0, 10.0],
    )
    assert res["measured"] is False
    assert res["handwriting_score"] is None
    assert res["opencv_cc_decay_pct"] is None


def test_a_missing_or_undecodable_photo_is_not_scored_as_healthy_writing():
    missing = analyze_handwriting_opencv(image_bytes=None)
    garbage = analyze_handwriting_opencv(image_bytes=b"not-a-jpeg")
    assert missing["measured"] is False
    assert missing["handwriting_score"] is None
    assert garbage["measured"] is False
    assert garbage["handwriting_score"] is None


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
