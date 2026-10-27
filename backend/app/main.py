import base64
from contextlib import asynccontextmanager
from datetime import datetime
import json
from pathlib import Path
from typing import Any, Dict, Optional

from fastapi import Depends, FastAPI, Query, Request
from fastapi.responses import HTMLResponse, Response

from app.clients.baseten_llm import baseten_client
from app.clients.circuit_breaker import RequestDeadlineContext
from app.clients.meta_models import meta_client
from app.db import (
    execute_write,
    fetch_all,
    fetch_one,
    init_db,
    purge_expired_telemetry,
    wipe_patient_data,
)
from app.models import (
    DoseLogCreate,
    FallEventCreate,
    FoGEventCreate,
    HandwritingAnalyzeRequest,
    HomeMotorExamCreate,
    MealProteinAnalyzeRequest,
    RealityCheckRequest,
    VoiceLogCreate,
)
from app.security import (
    AuthContext,
    require_any_authenticated_role,
    require_device_writer,
    verify_twilio_signature,
)
from app.services.diary_engine import DiaryBucketMetrics, classify_diary_bucket
from app.services.fall_escalation import fall_escalation_manager
from app.services.handwriting import analyze_handwriting_opencv
from app.services.motor_exam import MotorExamInput, score_home_motor_exam
from app.services.protein_checker import (
    FOOD_CANDIDATE_VOCAB,
    check_dose_protein_conflict,
    estimate_meal_protein,
)
from app.services.reality_check import run_reality_check_pipeline


@asynccontextmanager
async def lifespan(app: FastAPI):
    await init_db()
    await purge_expired_telemetry()
    yield


app = FastAPI(
    title="Cadence Clinical Orchestrator API",
    version="1.0.0",
    lifespan=lifespan,
)

STATIC_DIR = Path(__file__).parent / "static"


@app.get("/health")
async def health_check() -> Dict[str, str]:
    return {"status": "ok", "service": "cadence-clinical-orchestrator", "version": "1.0.0"}


@app.get("/dashboard", response_class=HTMLResponse)
async def get_neurologist_dashboard_shell() -> HTMLResponse:
    """
    Public HTML shell route (200 OK).
    Prompts for the Clinician/Device Bearer token in-page (stored in sessionStorage;
    never in URL query parameters) and fetches /api/v1/report/neurologist with Authorization header.
    """
    html_path = STATIC_DIR / "neurologist_dashboard.html"
    return HTMLResponse(content=html_path.read_text(encoding="utf-8"), status_code=200)


# ==================== PIPELINE 1: FREEZING OF GAIT (FoG) ====================
@app.post("/api/v1/events/fog")
async def log_fog_event(
    payload: FoGEventCreate,
    auth: AuthContext = Depends(require_device_writer),
) -> Dict[str, Any]:
    await execute_write(
        """
        INSERT INTO fog_events (
            patient_id, event_uuid, timestamp_utc, duration_sec, peak_freeze_index,
            locomotor_band_power, freeze_band_power, sampled_hz, arming_mode,
            speech_active_modifier, cue_bpm, recovery_latency_sec
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(event_uuid) DO NOTHING
        """,
        (
            auth.patient_id,
            payload.event_uuid,
            payload.timestamp_utc,
            payload.duration_sec,
            payload.peak_freeze_index,
            payload.locomotor_band_power,
            payload.freeze_band_power,
            payload.sampled_hz,
            payload.arming_mode,
            1 if payload.speech_active_modifier else 0,
            payload.cue_bpm,
            payload.recovery_latency_sec,
        ),
    )
    return {"status": "logged", "event_uuid": payload.event_uuid}


# ==================== PIPELINE 2: FALL DETECTION & ESCALATION ====================
@app.post("/api/v1/events/fall")
async def log_and_escalate_fall(
    payload: FallEventCreate,
    auth: AuthContext = Depends(require_device_writer),
) -> Dict[str, Any]:
    return await fall_escalation_manager.ingest_fall_event(
        patient_id=auth.patient_id,
        payload=payload,
        start_background_retry=True,
    )


@app.post("/api/v1/events/fall/{event_uuid}/cancel")
async def cancel_dispatched_fall_alert(
    event_uuid: str,
    auth: AuthContext = Depends(require_device_writer),
) -> Dict[str, Any]:
    return await fall_escalation_manager.cancel_dispatched_fall(
        patient_id=auth.patient_id,
        event_uuid=event_uuid,
    )


@app.post("/api/v1/webhooks/twilio/gather")
async def twilio_gather_webhook(
    request: Request,
    event_uuid: str = Query(...),
    params: dict = Depends(verify_twilio_signature),
) -> Response:
    digits = str(params.get("Digits", ""))
    res = await fall_escalation_manager.handle_gather_webhook(
        event_uuid=event_uuid,
        digits=digits,
    )
    if res["acknowledged"]:
        twiml = (
            '<?xml version="1.0" encoding="UTF-8"?>'
            "<Response><Say>Thank you. Alert acknowledged.</Say></Response>"
        )
    else:
        twiml = (
            '<?xml version="1.0" encoding="UTF-8"?>'
            "<Response><Say>Unrecognized input.</Say></Response>"
        )
    return Response(content=twiml, media_type="application/xml")


@app.post("/api/v1/webhooks/twilio/status")
async def twilio_status_webhook(
    request: Request,
    event_uuid: str = Query(...),
    params: dict = Depends(verify_twilio_signature),
) -> Dict[str, Any]:
    call_status = str(params.get("CallStatus", ""))
    return await fall_escalation_manager.handle_status_webhook(
        event_uuid=event_uuid,
        call_status=call_status,
    )


# ==================== PIPELINE 3: DOSE & PLATE-NORMALIZED PROTEIN ====================
@app.post("/api/v1/medication/dose")
async def log_medication_dose(
    payload: DoseLogCreate,
    auth: AuthContext = Depends(require_device_writer),
) -> Dict[str, Any]:
    await execute_write(
        """
        INSERT INTO medication_logs (
            patient_id, event_uuid, timestamp_utc, event_type,
            medication_name, scheduled_time_utc
        ) VALUES (?, ?, ?, 'dose_taken', ?, ?)
        ON CONFLICT(event_uuid) DO NOTHING
        """,
        (
            auth.patient_id,
            payload.event_uuid,
            payload.timestamp_utc,
            payload.medication_name,
            payload.scheduled_time_utc or payload.timestamp_utc,
        ),
    )
    return {"status": "logged", "event_uuid": payload.event_uuid, "event_type": "dose_taken"}


@app.post("/api/v1/medication/meal-protein")
async def analyze_meal_protein(
    payload: MealProteinAnalyzeRequest,
    auth: AuthContext = Depends(require_device_writer),
) -> Dict[str, Any]:
    deadline = RequestDeadlineContext()
    img_bytes = (
        base64.b64decode(payload.image_base64) if payload.image_base64 else None
    )
    sam_res = await meta_client.segment_sam_3_1(
        image_bytes=img_bytes,
        candidate_labels=FOOD_CANDIDATE_VOCAB,
        deadline=deadline,
        simulated_masks=payload.simulated_masks,
    )
    masks = sam_res.get("masks", []) if sam_res.get("sam_verified") else []
    protein_est = estimate_meal_protein(masks)

    latest_dose = await fetch_one(
        """
        SELECT timestamp_utc FROM medication_logs
        WHERE patient_id = ? AND event_type = 'dose_taken'
        ORDER BY timestamp_utc DESC LIMIT 1
        """,
        (auth.patient_id,),
    )
    dose_ts = latest_dose["timestamp_utc"] if latest_dose else None
    conflict = check_dose_protein_conflict(
        meal_timestamp_iso=payload.timestamp_utc,
        estimated_protein_grams=protein_est["estimated_protein_grams"],
        dose_timestamp_iso=dose_ts,
    )

    await execute_write(
        """
        INSERT INTO medication_logs (
            patient_id, event_uuid, timestamp_utc, event_type,
            detected_foods_json, plate_detected, plate_area_ratio,
            estimated_protein_grams, conflict_detected
        ) VALUES (?, ?, ?, 'meal_logged', ?, ?, ?, ?, ?)
        ON CONFLICT(event_uuid) DO NOTHING
        """,
        (
            auth.patient_id,
            payload.event_uuid,
            payload.timestamp_utc,
            json.dumps(protein_est["items"]),
            1 if protein_est["plate_detected"] else 0,
            protein_est["plate_area_ratio"],
            protein_est["estimated_protein_grams"],
            1 if conflict else 0,
        ),
    )

    if conflict:
        spoken = (
            f"High-protein meal (~{protein_est['estimated_protein_grams']:.0f} grams) "
            "logged near your Levodopa window. Noted in your diary for your neurologist."
        )
    else:
        spoken = f"Meal logged (~{protein_est['estimated_protein_grams']:.0f} grams of protein)."

    return {
        "event_uuid": payload.event_uuid,
        **protein_est,
        "conflict_detected": conflict,
        "spoken_response": spoken,
    }


# ==================== PIPELINE 4: HALLUCINATION REALITY CHECK ====================
@app.post("/api/v1/reality-check")
async def reality_check_endpoint(
    payload: RealityCheckRequest,
    auth: AuthContext = Depends(require_device_writer),
) -> Dict[str, Any]:
    img_bytes = (
        base64.b64decode(payload.image_base64) if payload.image_base64 else None
    )
    res = await run_reality_check_pipeline(
        user_query=payload.user_query,
        image_bytes=img_bytes,
        simulated_sam_masks=payload.simulated_sam_masks,
    )

    await execute_write(
        """
        INSERT INTO reality_checks (
            patient_id, event_uuid, timestamp_utc, user_query,
            sam_verified, sam_masks_json, living_subject_present,
            chosen_inanimate_label, template_id, spoken_response, latency_ms
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(event_uuid) DO NOTHING
        """,
        (
            auth.patient_id,
            payload.event_uuid,
            payload.timestamp_utc,
            payload.user_query,
            1 if res["sam_verified"] else 0,
            json.dumps(res["verified_masks"]),
            1 if res["living_subject_present"] else 0,
            res["chosen_inanimate_label"],
            res["template_id"],
            res["spoken_response"],
            res["latency_ms"],
        ),
    )
    return {"event_uuid": payload.event_uuid, **res}


# ==================== PIPELINE 5: HANDWRITING & VOICE VOLUME ====================
@app.post("/api/v1/handwriting/analyze")
async def analyze_handwriting_endpoint(
    payload: HandwritingAnalyzeRequest,
    auth: AuthContext = Depends(require_device_writer),
) -> Dict[str, Any]:
    img_bytes = (
        base64.b64decode(payload.image_base64) if payload.image_base64 else None
    )
    res = analyze_handwriting_opencv(
        image_bytes=img_bytes,
        simulated_letter_heights_px=payload.simulated_letter_heights_px,
        simulated_sam_decay_pct=payload.simulated_sam_decay_pct,
    )

    await execute_write(
        """
        INSERT INTO handwriting_logs (
            patient_id, event_uuid, timestamp_utc, letter_boxes_json,
            initial_stroke_height_px, final_stroke_height_px,
            opencv_cc_decay_pct, sam_3_1_decay_pct,
            micrographia_detected, deskew_angle_deg, source_context
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(event_uuid) DO NOTHING
        """,
        (
            auth.patient_id,
            payload.event_uuid,
            payload.timestamp_utc,
            json.dumps(res["letter_boxes"]),
            res["initial_stroke_height_px"],
            res["final_stroke_height_px"],
            res["opencv_cc_decay_pct"],
            res["sam_3_1_decay_pct"],
            1 if res["micrographia_detected"] else 0,
            res["deskew_angle_deg"],
            payload.source_context,
        ),
    )

    if res["micrographia_detected"]:
        shrink_abs = abs(res["opencv_cc_decay_pct"])
        spoken = (
            f"Your letters shrank by {shrink_abs:.0f}% across the line—pause, "
            "relax your hand, and aim for tall strokes."
        )
    else:
        spoken = "Your handwriting stroke height looks steady."

    return {"event_uuid": payload.event_uuid, **res, "spoken_response": spoken}


@app.post("/api/v1/events/voice")
async def log_voice_event(
    payload: VoiceLogCreate,
    auth: AuthContext = Depends(require_device_writer),
) -> Dict[str, Any]:
    await execute_write(
        """
        INSERT INTO voice_logs (
            patient_id, event_uuid, timestamp_utc, window_mean_dbfs,
            baseline_dbfs, nudge_triggered
        ) VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(event_uuid) DO NOTHING
        """,
        (
            auth.patient_id,
            payload.event_uuid,
            payload.timestamp_utc,
            payload.window_mean_dbfs,
            payload.baseline_dbfs,
            1 if payload.nudge_triggered else 0,
        ),
    )
    return {"status": "logged", "event_uuid": payload.event_uuid}


# ==================== PIPELINE 6: GUIDED HOME MOTOR EXAM ====================
@app.post("/api/v1/exam/complete")
async def complete_home_motor_exam(
    payload: HomeMotorExamCreate,
    auth: AuthContext = Depends(require_device_writer),
) -> Dict[str, Any]:
    scores = score_home_motor_exam(
        MotorExamInput(
            voice_mean_dbfs=payload.voice_mean_dbfs,
            voice_stability_db=payload.voice_stability_db,
            handwriting_opencv_decay_pct=payload.handwriting_opencv_decay_pct,
            handwriting_sam_decay_pct=payload.handwriting_sam_decay_pct,
            walk_cadence_spm=payload.walk_cadence_spm,
            walk_mean_fi=payload.walk_mean_fi,
            walk_fog_count=payload.walk_fog_count,
        )
    )

    latest_dose = await fetch_one(
        """
        SELECT timestamp_utc FROM medication_logs
        WHERE patient_id = ? AND event_type = 'dose_taken'
        ORDER BY timestamp_utc DESC LIMIT 1
        """,
        (auth.patient_id,),
    )
    minutes_since_dose: Optional[int] = None
    has_dose = False
    if latest_dose:
        try:
            t_exam = datetime.fromisoformat(payload.timestamp_utc.replace("Z", "+00:00"))
            t_dose = datetime.fromisoformat(
                str(latest_dose["timestamp_utc"]).replace("Z", "+00:00")
            )
            diff_min = int((t_exam - t_dose).total_seconds() // 60)
            if 0 <= diff_min <= 720:
                has_dose = True
                minutes_since_dose = diff_min
        except Exception:
            pass

    diary_eval = classify_diary_bucket(
        DiaryBucketMetrics(
            fall_occurred=False,
            fog_count=payload.walk_fog_count,
            mean_fi=payload.walk_mean_fi,
            opencv_decay_pct=payload.handwriting_opencv_decay_pct,
            mean_voice_dbfs=payload.voice_mean_dbfs,
            has_exam=True,
            exam_composite_score=scores["composite_motor_score"],
            has_dose=has_dose,
            minutes_since_last_dose=minutes_since_dose,
            protein_conflict_active=False,
        )
    )

    clinical_summary = (
        f"Guided Home Motor Exam ({diary_eval['clinical_state']}): "
        f"Composite {scores['composite_motor_score']:.1f}/100 "
        f"(Voice {scores['voice_score']:.1f}, Writing {scores['handwriting_score']:.1f}, "
        f"Gait {scores['gait_score']:.1f})."
    )

    await execute_write(
        """
        INSERT INTO motor_exams (
            patient_id, exam_uuid, timestamp_utc, medication_state_label,
            minutes_since_last_dose, voice_mean_dbfs, voice_stability_db,
            voice_score, handwriting_opencv_decay_pct, handwriting_sam_decay_pct,
            handwriting_score, walk_cadence_spm, walk_mean_fi, walk_fog_count,
            gait_score, composite_motor_score, clinical_summary
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(exam_uuid) DO NOTHING
        """,
        (
            auth.patient_id,
            payload.exam_uuid,
            payload.timestamp_utc,
            diary_eval["clinical_state"],
            minutes_since_dose,
            payload.voice_mean_dbfs,
            payload.voice_stability_db,
            scores["voice_score"],
            payload.handwriting_opencv_decay_pct,
            payload.handwriting_sam_decay_pct,
            scores["handwriting_score"],
            payload.walk_cadence_spm,
            payload.walk_mean_fi,
            payload.walk_fog_count,
            scores["gait_score"],
            scores["composite_motor_score"],
            clinical_summary,
        ),
    )

    return {
        "exam_uuid": payload.exam_uuid,
        "medication_state_label": diary_eval["clinical_state"],
        "symptom_burden_score": diary_eval["symptom_burden_score"],
        "minutes_since_last_dose": minutes_since_dose,
        **scores,
        "clinical_summary": clinical_summary,
    }


@app.get("/api/v1/exam/history")
async def get_exam_history(
    auth: AuthContext = Depends(require_any_authenticated_role),
) -> Dict[str, Any]:
    exams = await fetch_all(
        "SELECT * FROM motor_exams WHERE patient_id = ? ORDER BY timestamp_utc DESC LIMIT 50",
        (auth.patient_id,),
    )
    return {"patient_id": auth.patient_id, "exams": exams}


# ==================== PIPELINE 7: NEUROLOGIST REPORT & PATIENT WIPE ====================
@app.get("/api/v1/report/neurologist")
async def get_neurologist_report(
    auth: AuthContext = Depends(require_any_authenticated_role),
) -> Dict[str, Any]:
    pid = auth.patient_id
    fog_rows = await fetch_all(
        "SELECT * FROM fog_events WHERE patient_id = ? ORDER BY timestamp_utc DESC LIMIT 100",
        (pid,),
    )
    fall_rows = await fetch_all(
        "SELECT * FROM fall_events WHERE patient_id = ? ORDER BY timestamp_utc DESC LIMIT 50",
        (pid,),
    )
    med_rows = await fetch_all(
        "SELECT * FROM medication_logs WHERE patient_id = ? ORDER BY timestamp_utc DESC LIMIT 100",
        (pid,),
    )
    reality_rows = await fetch_all(
        "SELECT * FROM reality_checks WHERE patient_id = ? ORDER BY timestamp_utc DESC LIMIT 50",
        (pid,),
    )
    writing_rows = await fetch_all(
        "SELECT * FROM handwriting_logs WHERE patient_id = ? ORDER BY timestamp_utc DESC LIMIT 50",
        (pid,),
    )
    exam_rows = await fetch_all(
        "SELECT * FROM motor_exams WHERE patient_id = ? ORDER BY timestamp_utc DESC LIMIT 50",
        (pid,),
    )

    state_counts = {"ON": 0, "WEARING_OFF": 0, "OFF": 0, "NO_DOSE": 0}
    for ex in exam_rows:
        lbl = ex.get("medication_state_label", "NO_DOSE")
        if lbl in state_counts:
            state_counts[lbl] += 1

    total_classified = max(1, sum(state_counts.values()))
    summary_stats = {
        "on_pct": round(100.0 * state_counts["ON"] / total_classified, 1),
        "wearing_off_pct": round(100.0 * state_counts["WEARING_OFF"] / total_classified, 1),
        "off_pct": round(100.0 * state_counts["OFF"] / total_classified, 1),
        "no_dose_pct": round(100.0 * state_counts["NO_DOSE"] / total_classified, 1),
        "fog_count": len(fog_rows),
        "fall_count": len([f for f in fall_rows if f.get("status") != "canceled_false_alarm"]),
        "latest_exam_score": exam_rows[0]["composite_motor_score"] if exam_rows else None,
    }
    narrative = await baseten_client.summarize_clinical_diary(summary_stats)

    return {
        "patient_id": pid,
        "summary_stats": summary_stats,
        "clinical_narrative": narrative,
        "motor_exams": exam_rows,
        "fog_events": fog_rows,
        "fall_events": fall_rows,
        "medication_logs": med_rows,
        "reality_checks": reality_rows,
        "handwriting_logs": writing_rows,
    }


@app.delete("/api/v1/patient/data")
async def delete_patient_data(
    auth: AuthContext = Depends(require_device_writer),
) -> Dict[str, Any]:
    deleted_counts = await wipe_patient_data(auth.patient_id)
    return {
        "status": "wiped",
        "patient_id": auth.patient_id,
        "deleted_rows": deleted_counts,
    }
