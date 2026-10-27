from app.services.diary_engine import DiaryBucketMetrics, classify_diary_bucket
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
