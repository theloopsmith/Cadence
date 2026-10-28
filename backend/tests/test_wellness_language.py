"""What people read must describe events and raw measurements, never a clinical state or a score."""

import asyncio
import re

import pytest
from fastapi.testclient import TestClient

from app.clients.baseten_llm import baseten_client
from app.config import settings
from app.db import init_db_sync
from app.main import app
from app.services.plain_language import describe_letter_change, describe_task_metrics, summarize_day

DEVICE_HEADERS = {"Authorization": f"Bearer {settings.cadence_device_token}"}

FORBIDDEN = re.compile(
    r"\b(ON|OFF|WEARING[_ -]?OFF|score|composite|/100|clinical|symptom|severity|"
    r"micrographia|hallucinat\w*|diagnos\w*)\b",
    re.IGNORECASE,
)


def assert_plain(text: str) -> None:
    match = FORBIDDEN.search(text)
    assert match is None, f"{match.group(0)!r} in: {text}"


def test_letter_change_is_described_in_plain_words():
    assert describe_letter_change(-22.4) == "letters got 22% smaller across the line"
    assert describe_letter_change(-3.0) == "letters stayed about the same size across the line"
    assert describe_letter_change(12.0) == "letters got 12% larger across the line"
    assert describe_letter_change(None) == "handwriting was not measured"


def test_task_metrics_are_raw_measurements():
    text = describe_task_metrics(
        voice_mean_dbfs=-28.0,
        handwriting_decay_pct=-35.0,
        walk_cadence_spm=85.0,
        walk_fog_count=1,
    )
    assert "letters got 35% smaller across the line" in text
    assert "-28 dB" in text
    assert "85 steps a minute" in text
    assert "1 freeze during the walk" in text
    assert_plain(text)


def test_task_metrics_skip_what_was_not_measured():
    text = describe_task_metrics(
        voice_mean_dbfs=None, handwriting_decay_pct=None, walk_cadence_spm=0.0, walk_fog_count=0
    )
    assert "handwriting was not measured" in text
    assert "steps a minute" not in text
    assert_plain(text)


def test_day_summary_counts_events_without_interpreting_them():
    text = summarize_day(
        {
            "fog_count": 2,
            "fall_count": 1,
            "fall_candidate_resolved_count": 1,
            "dose_count": 3,
            "latest_exam_metrics": {
                "voice_mean_dbfs": -26.0,
                "handwriting_opencv_decay_pct": -22.0,
                "walk_cadence_spm": 96.0,
                "walk_fog_count": 0,
            },
            # Present in the stats; must not leak into the words.
            "on_pct": 60.0,
            "off_pct": 20.0,
            "latest_exam_score": 64.0,
        }
    )
    assert "3 doses logged" in text
    assert "2 times" in text
    assert "1 fall" in text
    assert "answered as okay" in text
    assert "letters got 22% smaller" in text
    assert "60" not in text and "64" not in text
    assert_plain(text)


def test_an_empty_day_says_so():
    text = summarize_day({"fog_count": 0, "fall_count": 0, "dose_count": 0})
    assert "nothing" in text.lower() or "no events" in text.lower()
    assert_plain(text)


def test_the_deterministic_narrative_is_plain():
    text = asyncio.run(
        baseten_client.summarize_clinical_diary(
            {"fog_count": 1, "fall_count": 0, "dose_count": 2, "on_pct": 80.0, "latest_exam_score": 70.0}
        )
    )
    assert_plain(text)


@pytest.fixture
def client(monkeypatch, tmp_path):
    monkeypatch.setattr(settings, "sqlite_db_path", str(tmp_path / "plain.db"))
    init_db_sync()
    with TestClient(app) as http:
        yield http


def test_motor_check_summary_is_plain(client):
    res = client.post(
        "/api/v1/exam/complete",
        headers=DEVICE_HEADERS,
        json={
            "exam_uuid": "plain-exam-001",
            "voice_mean_dbfs": -28.0,
            "voice_stability_db": 3.5,
            "handwriting_opencv_decay_pct": -35.0,
            "walk_cadence_spm": 85.0,
            "walk_mean_fi": 2.2,
            "walk_fog_count": 1,
        },
    )
    assert res.status_code == 200
    summary = res.json()["clinical_summary"]
    assert "letters got 35% smaller" in summary
    assert_plain(summary)


def test_report_narrative_is_plain_and_counts_doses(client):
    client.post(
        "/api/v1/medication/dose",
        headers=DEVICE_HEADERS,
        json={"event_uuid": "plain-dose-001"},
    )
    body = client.get("/api/v1/report/neurologist", headers=DEVICE_HEADERS).json()
    assert body["summary_stats"]["dose_count"] == 1
    assert "1 dose logged" in body["clinical_narrative"]
    assert_plain(body["clinical_narrative"])


def test_meal_reply_is_general_information(client):
    client.post("/api/v1/medication/dose", headers=DEVICE_HEADERS, json={"event_uuid": "plain-dose-002"})
    res = client.post(
        "/api/v1/medication/meal-protein",
        headers=DEVICE_HEADERS,
        json={
            "event_uuid": "plain-meal-001",
            "simulated_masks": [{"label": "steak", "area_px": 1000, "confidence": 0.9}],
        },
    )
    spoken = res.json()["spoken_response"]
    assert_plain(spoken)
    assert "neurologist" not in spoken.lower()
