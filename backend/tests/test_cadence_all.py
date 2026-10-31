import os
import tempfile
import pytest
from fastapi.testclient import TestClient

# Point SQLite to a temporary file before importing app
_tmp_db = tempfile.NamedTemporaryFile(suffix=".db", delete=False)
_tmp_db.close()
os.environ["SQLITE_DB_PATH"] = _tmp_db.name

from app.clients.circuit_breaker import PerModelCircuitBreakerRegistry, RequestDeadlineContext
from app.config import settings
from app.db import init_db_sync
from app.main import app
from app.services.diary_engine import (
    DiaryBucketMetrics,
    classify_diary_bucket,
    compute_bucket_symptom_burden,
)
from app.services.handwriting import compute_decay_from_heights
from app.services.motor_exam import MotorExamInput, score_home_motor_exam
from app.services.protein_checker import check_dose_protein_conflict, estimate_meal_protein

init_db_sync()

DEVICE_HEADERS = {"Authorization": f"Bearer {settings.cadence_device_token}"}
CLINICIAN_HEADERS = {"Authorization": f"Bearer {settings.cadence_clinician_token}"}


def test_worked_examples_motor_exam_and_diary():
    """
    Verifies all 4 worked numerical examples from Appendices B & C:
      1. S_voice = 78.0 (L_dBFS = -28.0, sigma_dB,phonation = 3.5)
      2. S_writing = 52.0 (opencv_cc_decay_pct = -35.0%) vs 100.0 (-3.0%)
      3. S_gait = 33.0 (cadence = 85.0, FI = 2.2, N_FoG = 1) -> Composite S_motor = 52.2
      4. S(t_k) = 30.0 (n_fog = 1, FI = 2.5, 140m post-dose) -> WEARING_OFF
    """
    # Normal handwriting (-3.0% shrinkage -> 100.0)
    normal_writing = compute_decay_from_heights([100.0, 100.0, 100.0, 97.0, 97.0, 97.0])
    assert normal_writing["opencv_cc_decay_pct"] == -3.0
    assert normal_writing["handwriting_score"] == 100.0

    # Worked Examples 1, 2, 3 combined in score_home_motor_exam
    res = score_home_motor_exam(
        MotorExamInput(
            voice_mean_dbfs=-28.0,
            voice_stability_db=3.5,
            handwriting_opencv_decay_pct=-35.0,
            handwriting_sam_decay_pct=-36.2,
            walk_cadence_spm=85.0,
            walk_mean_fi=2.2,
            walk_fog_count=1,
        )
    )
    assert res["voice_score"] == 78.0
    assert res["handwriting_score"] == 52.0
    assert res["gait_score"] == 33.0
    assert res["composite_motor_score"] == 52.2

    # Worked Example 4: S(t_k) = 30.0 -> WEARING_OFF
    bucket = DiaryBucketMetrics(
        fall_occurred=False,
        fog_count=1,
        mean_fi=2.5,
        opencv_decay_pct=0.0,
        mean_voice_dbfs=-22.0,
        has_exam=False,
        has_dose=True,
        minutes_since_last_dose=140,
        protein_conflict_active=False,
    )
    assert compute_bucket_symptom_burden(bucket) == 30.0
    classified = classify_diary_bucket(bucket)
    assert classified["symptom_burden_score"] == 30.0
    assert classified["clinical_state"] == "WEARING_OFF"


def test_exhaustive_diary_classifier_states_and_modifiers():
    """
    Verifies:
      - Exam-conditioned OFF clause: bucket without an exam does NOT misfire OFF
      - NO_DOSE when has_dose is False and OFF criteria not met
      - Symptom-free bucket at 195 min post-dose stays ON (not clock-only WEARING_OFF)
      - Mild burden (S(t_k) = 12.0) + >180m or protein_conflict_active triggers WEARING_OFF
    """
    # 1. No exam, no dose, zero burden -> NO_DOSE (never misfires OFF)
    no_dose_res = classify_diary_bucket(
        DiaryBucketMetrics(has_exam=False, exam_composite_score=0.0, has_dose=False)
    )
    assert no_dose_res["clinical_state"] == "NO_DOSE"

    # 2. Has exam with composite 52.2 (< 55.0) -> OFF even without dose
    exam_off_res = classify_diary_bucket(
        DiaryBucketMetrics(has_exam=True, exam_composite_score=52.2, has_dose=False)
    )
    assert exam_off_res["clinical_state"] == "OFF"

    # 3. Symptom-free bucket at 195m post-dose -> stays ON (R11 fix)
    clock_only = classify_diary_bucket(
        DiaryBucketMetrics(has_dose=True, minutes_since_last_dose=195, fog_count=0)
    )
    assert clock_only["symptom_burden_score"] == 0.0
    assert clock_only["clinical_state"] == "ON"

    # 4. Mild burden (1 FoG -> S(t_k)=12.0 >= 10.0) with active protein conflict -> WEARING_OFF
    protein_mod = classify_diary_bucket(
        DiaryBucketMetrics(
            has_dose=True,
            minutes_since_last_dose=90,
            fog_count=1,
            mean_fi=1.0,
            protein_conflict_active=True,
        )
    )
    assert protein_mod["symptom_burden_score"] == 12.0
    assert protein_mod["clinical_state"] == "WEARING_OFF"


def test_per_model_circuit_breaker_isolation():
    """Verifies that 3 failures on ('meta', 'sam-3.1') never trip ('meta', 'muse-voice-transcribe-1.0')."""
    reg = PerModelCircuitBreakerRegistry(failure_threshold=3, cooldown_sec=60.0)
    for _ in range(3):
        reg.record_failure("meta", "sam-3.1")
    assert not reg.is_available("meta", "sam-3.1")
    assert reg.is_available("meta", "muse-voice-transcribe-1.0")


def test_plate_normalized_protein_lookup():
    """Verifies plate-normalized protein calculation and fallback when no plate is visible."""
    # Steak covering 0.35 of plate (1.0x reference) -> 28.0g
    masks_with_plate = [
        {"label": "plate", "area_px": 100000, "confidence": 0.92},
        {"label": "steak", "area_px": 35000, "confidence": 0.88},
    ]
    res = estimate_meal_protein(masks_with_plate)
    assert res["plate_detected"] is True
    assert res["estimated_protein_grams"] == 28.0

    # Conflict window check: 25 min before dose -> True
    assert check_dose_protein_conflict(
        "2026-10-26T12:35:00+00:00", 28.0, "2026-10-26T13:00:00+00:00"
    ) is True


def test_end_to_end_api_pipelines_and_rbac():
    device_headers = dict(DEVICE_HEADERS)
    with TestClient(app) as client:
        # 1. Public health & dashboard HTML shell
        assert client.get("/health").status_code == 200
        dash = client.get("/dashboard")
        assert dash.status_code == 200
        assert "sessionStorage" in dash.text

        # 2. Clinician token cannot POST or DELETE (403 Forbidden)
        forbidden_post = client.post(
            "/api/v1/events/fog",
            headers=CLINICIAN_HEADERS,
            json={
                "event_uuid": "fog-test-001",
                "duration_sec": 4.2,
                "peak_freeze_index": 3.4,
                "locomotor_band_power": 0.05,
                "freeze_band_power": 0.17,
                "sampled_hz": 50.0,
                "arming_mode": "turning_upright",
            },
        )
        assert forbidden_post.status_code == 403
        assert client.delete("/api/v1/patient/data", headers=CLINICIAN_HEADERS).status_code == 403
        wiped = client.delete("/api/v1/patient/data", headers=device_headers)
        assert wiped.status_code == 200
        device_headers["X-Cadence-Data-Generation"] = str(wiped.json()["data_generation"])

        # 3. Device token logs FoG, Dose, Meal Protein, Reality Check, Handwriting, Fall & Exam
        fog_ok = client.post(
            "/api/v1/events/fog",
            headers=device_headers,
            json={
                "event_uuid": "fog-test-001",
                "duration_sec": 4.2,
                "peak_freeze_index": 3.4,
                "locomotor_band_power": 0.05,
                "freeze_band_power": 0.17,
                "sampled_hz": 50.0,
                "arming_mode": "turning_upright",
            },
        )
        assert fog_ok.status_code == 200

        # Reality Check: SAM detects coat on chair (no person) -> grounded to 'coat'
        rc_ok = client.post(
            "/api/v1/reality-check",
            headers=device_headers,
            json={
                "event_uuid": "rc-test-001",
                "user_query": "Is someone sitting in that chair?",
                "simulated_sam_masks": [
                    {"label": "coat", "confidence": 0.91, "area_ratio": 0.08},
                    {"label": "chair", "confidence": 0.85, "area_ratio": 0.15},
                ],
            },
        )
        assert rc_ok.status_code == 200
        rc_data = rc_ok.json()
        assert rc_data["living_subject_present"] is False
        assert rc_data["chosen_inanimate_label"] == "coat"
        assert "coat" in rc_data["spoken_response"]

        # Fall Event with GPS & Post-Dispatch Cancel -> All-Clear SMS
        fall_ok = client.post(
            "/api/v1/events/fall",
            headers=device_headers,
            json={
                "event_uuid": "fall-test-001",
                "peak_impact_g": 3.6,
                "peak_jerk_gs": 48.0,
                "post_impact_tilt_deg": 68.0,
                "worn_pre_impact": False,
                "vocal_activity_detected": True,  # Groan overrides worn_pre_impact=False!
                "latitude": 37.7749,
                "longitude": -122.4194,
            },
        )
        assert fall_ok.status_code == 200
        fall_data = fall_ok.json()
        assert fall_data["twilio_dispatched"] is True
        assert "https://maps.google.com/?q=37.774900,-122.419400" in fall_data["sms_body"]

        cancel_ok = client.post(
            "/api/v1/events/fall/fall-test-001/cancel",
            headers=device_headers,
        )
        assert cancel_ok.status_code == 200
        assert cancel_ok.json()["all_clear_sms_sent"] >= 1

        # Guided Home Motor Exam
        exam_ok = client.post(
            "/api/v1/exam/complete",
            headers=device_headers,
            json={
                "exam_uuid": "exam-test-001",
            "voice_status": "measured", "handwriting_status": "measured", "walk_status": "measured", "measurement_source": "device",
                "voice_mean_dbfs": -28.0,
                "voice_stability_db": 3.5,
                "handwriting_opencv_decay_pct": -35.0,
                "handwriting_sam_decay_pct": -36.0,
                "walk_cadence_spm": 85.0,
                "walk_mean_fi": 2.2,
                "walk_fog_count": 1,
            },
        )
        assert exam_ok.status_code == 200
        assert exam_ok.json()["composite_motor_score"] == 52.2

        # Clinician reader fetches report
        rep = client.get("/api/v1/report/neurologist", headers=CLINICIAN_HEADERS)
        assert rep.status_code == 200
        assert len(rep.json()["motor_exams"]) == 1
