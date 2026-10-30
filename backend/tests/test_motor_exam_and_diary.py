from datetime import datetime, timezone
from app.services.diary_engine import (
    DiaryBucketMetrics,
    build_24h_diary_timeline,
    classify_diary_bucket,
)
from app.services.motor_exam import MotorExamInput, score_home_motor_exam


def test_motor_exam_and_diary_formulas():
    scores = score_home_motor_exam(
        MotorExamInput(
            voice_mean_dbfs=-28.0,
            voice_stability_db=3.5,
            handwriting_opencv_decay_pct=-35.0,
            handwriting_sam_decay_pct=-36.0,
            walk_cadence_spm=85.0,
            walk_mean_fi=2.2,
            walk_fog_count=1,
        )
    )
    assert scores == {
        "voice_score": 78.0,
        "handwriting_score": 52.0,
        "gait_score": 33.0,
        "composite_motor_score": 52.2,
    }

    diary = classify_diary_bucket(
        DiaryBucketMetrics(
            fog_count=1,
            mean_fi=2.5,
            has_dose=True,
            minutes_since_last_dose=140,
        )
    )
    assert diary == {"symptom_burden_score": 30.0, "clinical_state": "WEARING_OFF"}


def test_build_24h_diary_timeline_and_on_off_exam_delta():
    med_rows = [
        {"timestamp_utc": "2026-10-26T08:00:00+00:00", "event_type": "dose_taken", "conflict_detected": 0},
    ]
    exam_rows = [
        {
            "timestamp_utc": "2026-10-26T09:15:00+00:00",
            "medication_state_label": "ON",
            "voice_mean_dbfs": -22.0,
            "voice_score": 95.0,
            "handwriting_opencv_decay_pct": -3.0,
            "handwriting_score": 100.0,
            "walk_cadence_spm": 108.0,
            "walk_mean_fi": 0.9,
            "walk_fog_count": 0,
            "gait_score": 100.0,
            "composite_motor_score": 98.5,
        },
        {
            "timestamp_utc": "2026-10-26T07:30:00+00:00",
            "medication_state_label": "OFF",
            "voice_mean_dbfs": -28.0,
            "voice_score": 78.0,
            "handwriting_opencv_decay_pct": -35.0,
            "handwriting_score": 52.0,
            "walk_cadence_spm": 85.0,
            "walk_mean_fi": 2.2,
            "walk_fog_count": 1,
            "gait_score": 33.0,
            "composite_motor_score": 52.2,
        },
    ]
    tl = build_24h_diary_timeline(
        fog_rows=[],
        fall_rows=[],
        med_rows=med_rows,
        writing_rows=[],
        voice_rows=[],
        exam_rows=exam_rows, reference_end_utc=datetime(2026,10,26,20,tzinfo=timezone.utc),
    )
    assert len(tl["buckets"]) >= 8
    assert tl["exam_on_vs_off_delta"] is not None
    assert tl["exam_on_vs_off_delta"]["composite_improvement_pts"] == 46.3


def test_demo_seed_and_neurologist_report_endpoint():
    from fastapi.testclient import TestClient
    from app.main import app

    headers = {"Authorization": "Bearer cadence-dev-device-writer-token-2026"}
    with TestClient(app) as client:
        seed_res = client.post("/api/v1/demo/seed", headers=headers)
        assert seed_res.status_code == 200
        assert seed_res.json()["status"] == "seeded"

        rep_res = client.get("/api/v1/report/neurologist", headers=headers)
        assert rep_res.status_code == 200
        body = rep_res.json()
        assert len(body["motor_exams"]) >= 2
        assert len(body["buckets_24h"]) >= 8
        assert body["summary_stats"]["exam_on_vs_off_delta"] is not None
