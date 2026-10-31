"""A dose logged after a meal or an exam must not be the dose those events are judged against."""

import pytest
from fastapi.testclient import TestClient

from app.config import settings
from app.db import init_db_sync
from app.main import app

DEVICE_HEADERS = {"Authorization": f"Bearer {settings.cadence_device_token}"}

MORNING_DOSE = "2020-01-01T08:00:00+00:00"
EVENING_DOSE = "2020-01-01T17:30:00+00:00"
MEAL_AT = "2020-01-01T08:20:00+00:00"
EXAM_AT = "2020-01-01T09:15:00+00:00"


@pytest.fixture
def client(monkeypatch, tmp_path):
    monkeypatch.setattr(settings, "sqlite_db_path", str(tmp_path / "dose.db"))
    init_db_sync()
    with TestClient(app) as http:
        yield http


def _log_dose(client: TestClient, event_uuid: str, timestamp: str) -> None:
    response = client.post(
        "/api/v1/medication/dose",
        headers=DEVICE_HEADERS,
        json={"event_uuid": event_uuid, "timestamp_utc": timestamp},
    )
    assert response.status_code == 200


def test_meal_uses_the_dose_already_taken_not_one_logged_later(client):
    """
    Steak twenty minutes after the morning dose is inside the protein window.
    An evening dose logged afterward is the newest row, and the meal was
    judged against that instead, so the conflict disappeared.
    """
    _log_dose(client, "dose-morning-2099", MORNING_DOSE)
    _log_dose(client, "dose-evening-2099", EVENING_DOSE)

    meal = client.post(
        "/api/v1/medication/meal-protein",
        headers=DEVICE_HEADERS,
        json={
            "event_uuid": "meal-morning-2099",
            "timestamp_utc": MEAL_AT,
            "simulated_masks": [
                {"label": "steak", "area_px": 10000, "confidence": 0.9},
            ],
        },
    )
    assert meal.status_code == 200
    assert meal.json()["estimated_protein_grams"] > 15
    assert meal.json()["conflict_detected"] is True


def test_exam_uses_the_dose_already_taken_not_one_logged_later(client):
    """
    A strong exam 75 minutes after the morning dose is ON. Judging it against
    the evening dose made the elapsed time negative, so the report stored
    NO_DOSE.
    """
    _log_dose(client, "dose-morning-exam-2099", MORNING_DOSE)
    _log_dose(client, "dose-evening-exam-2099", EVENING_DOSE)

    exam = client.post(
        "/api/v1/exam/complete",
        headers=DEVICE_HEADERS,
        json={
            "exam_uuid": "exam-dose-clock-2099",
            "voice_status": "measured", "handwriting_status": "measured", "walk_status": "measured", "measurement_source": "device",
            "timestamp_utc": EXAM_AT,
            "voice_mean_dbfs": -20.0,
            "voice_stability_db": 1.0,
            "handwriting_opencv_decay_pct": 0.0,
            "walk_cadence_spm": 110.0,
            "walk_mean_fi": 1.0,
            "walk_fog_count": 0,
        },
    )
    assert exam.status_code == 200
    body = exam.json()
    assert body["minutes_since_last_dose"] == 75
    assert body["medication_state_label"] == "ON"
