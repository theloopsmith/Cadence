import asyncio
import base64
import io
import wave
from contextlib import asynccontextmanager
from datetime import datetime, timezone
import json
from pathlib import Path
from typing import Any, Dict, Optional

from fastapi import Depends, FastAPI, HTTPException, Query, Request, status
from fastapi.responses import HTMLResponse, Response

from app.clients.baseten_llm import baseten_client
from app.clients.circuit_breaker import RequestDeadlineContext
from app.clients.fireworks_client import fireworks_client
from app.clients.meta_models import check_in_keywords, dose_keywords, meta_client
from app.config import settings
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
    LoginRequest,
    SpeechTranscribeRequest,
    MealProteinAnalyzeRequest,
    MealLogCreate,
    RealityCheckRequest,
    VoiceLogCreate,
)
from app.auth import AuthError, authenticate_sync, validate_security_settings
from app.security import (
    AuthContext,
    reject_simulated_inputs,
    require_any_authenticated_role,
    require_demo_mode,
    require_device_writer,
    verify_twilio_signature,
)
from app.errors import install_error_handlers
from app.services.dose_clock import dose_timestamp_at_or_before, parse_utc
from app.services.plain_language import describe_task_metrics
from app.services.diary_engine import (
    DiaryBucketMetrics,
    build_24h_diary_timeline,
    classify_diary_bucket,
)
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
    validate_security_settings()
    await init_db()
    await purge_expired_telemetry()
    await fall_escalation_manager.resume_open_escalations()
    yield
    await fall_escalation_manager.close()


app = FastAPI(
    title="Cadence Accessibility Companion API",
    version="1.0.0",
    lifespan=lifespan,
)
install_error_handlers(app)

STATIC_DIR = Path(__file__).parent / "static"


@app.get("/health")
async def health_check() -> Dict[str, str]:
    return {"status": "ok", "service": "cadence-accessibility-companion", "version": "1.0.0"}


@app.get("/dashboard", response_class=HTMLResponse)
async def get_neurologist_dashboard_shell() -> HTMLResponse:
    """
    Public HTML shell route (200 OK).
    Prompts for the Clinician/Device Bearer token in-page (stored in sessionStorage;
    never in URL query parameters) and fetches /api/v1/report/neurologist with Authorization header.
    """
    html_path = STATIC_DIR / "neurologist_dashboard.html"
    return HTMLResponse(content=html_path.read_text(encoding="utf-8"), status_code=200)


# ==================== SPEECH (Muse Voice Transcribe) ====================
MAX_CLIP_SECONDS = 30


def _validated_wav(audio_base64: str) -> bytes:
    try:
        data = base64.b64decode(audio_base64, validate=True)
        with wave.open(io.BytesIO(data), "rb") as clip:
            channels, width, rate, frames = (
                clip.getnchannels(), clip.getsampwidth(), clip.getframerate(), clip.getnframes()
            )
    except Exception:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="That clip isn't a WAV recording.")
    if channels != 1 or width != 2 or rate not in (16000, 24000):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Clips must be mono 16-bit audio at 16 or 24 kHz.",
        )
    if frames / rate > MAX_CLIP_SECONDS:
        raise HTTPException(
            status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
            detail=f"Clips can be at most {MAX_CLIP_SECONDS} seconds.",
        )
    return data


@app.post("/api/v1/speech/transcribe")
async def transcribe_speech(
    payload: SpeechTranscribeRequest,
    auth: AuthContext = Depends(require_device_writer),
) -> Dict[str, Any]:
    """Second listener next to the phone's on-device recognizer. Audio is not stored."""
    wav_bytes = _validated_wav(payload.audio_base64)
    extra = [k.strip()[:40] for k in payload.keywords if k.strip()]
    base = check_in_keywords() if payload.purpose == "fall_check_in" else dose_keywords()
    keywords = list(dict.fromkeys(base + extra))
    result = await meta_client.transcribe_muse_voice(wav_bytes, keywords=keywords)
    return {
        "available": result["available"],
        "transcript": result["transcript"],
        "source": "muse_voice_transcribe",
    }


# ==================== ACCOUNTS ====================
@app.post("/api/v1/auth/login")
async def login(payload: LoginRequest) -> Dict[str, Any]:
    try:
        issued = await asyncio.to_thread(authenticate_sync, payload.username, payload.password)
    except AuthError as exc:
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS if exc.locked else status.HTTP_401_UNAUTHORIZED,
            detail=str(exc),
        )
    return {
        "access_token": issued.access_token,
        "token_type": "bearer",
        "expires_in": issued.expires_in,
        "role": issued.role,
    }


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
    result = await fall_escalation_manager.ingest_fall_event(
        patient_id=auth.patient_id,
        payload=payload,
        start_background_retry=True,
    )
    if result.get("status") == "confirmed_waiting_dispatch" or (
        result.get("status") == "escalated_twilio" and not result.get("provider_accepted")
    ):
        raise HTTPException(status_code=503, detail="Alert saved; caregiver contact unavailable. Retrying is required.")
    return result


@app.get("/api/v1/events/fall/{event_uuid}/delivery")
async def get_fall_delivery(event_uuid: str, auth: AuthContext = Depends(require_any_authenticated_role)):
    return await fall_escalation_manager.delivery_status(auth.patient_id, event_uuid)


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
    attempt_id: Optional[str] = Query(None),
) -> Response:
    digits = str(params.get("Digits", ""))
    res = await fall_escalation_manager.handle_gather_webhook(
        event_uuid=event_uuid,
        digits=digits, call_sid=params.get("CallSid"), attempt_id=attempt_id,
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
    attempt_id: Optional[str] = Query(None),
) -> Dict[str, Any]:
    call_status = str(params.get("CallStatus", ""))
    return await fall_escalation_manager.handle_status_webhook(
        event_uuid=event_uuid,
        call_status=call_status, call_sid=params.get("CallSid"), attempt_id=attempt_id,
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


@app.post("/api/v1/meals/log")
async def log_meal_time(payload: MealLogCreate, auth: AuthContext = Depends(require_device_writer)) -> Dict[str, Any]:
    await execute_write(
        """INSERT INTO medication_logs (patient_id, event_uuid, timestamp_utc, event_type)
           VALUES (?, ?, ?, 'meal_logged') ON CONFLICT(event_uuid) DO NOTHING""",
        (auth.patient_id, payload.event_uuid, payload.timestamp_utc),
    )
    return {"event_uuid": payload.event_uuid, "timestamp_utc": payload.timestamp_utc,
            "estimated_protein_grams": None, "plate_detected": False,
            "conflict_detected": False, "items": [],
            "spoken_response": "Meal time logged in your routine diary."}


@app.post("/api/v1/medication/meal-protein", deprecated=True)
async def analyze_meal_protein(
    payload: MealProteinAnalyzeRequest,
    auth: AuthContext = Depends(require_device_writer),
) -> Dict[str, Any]:
    if not settings.enable_research_metrics:
        return await log_meal_time(MealLogCreate(event_uuid=payload.event_uuid, timestamp_utc=payload.timestamp_utc), auth)
    reject_simulated_inputs(simulated_masks=payload.simulated_masks)
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

    dose_ts = await dose_timestamp_at_or_before(auth.patient_id, payload.timestamp_utc)
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
            f"Meal logged, about {protein_est['estimated_protein_grams']:.0f} grams of protein, "
            "close to your Levodopa time. Some people find protein near a dose matters for them; "
            "it's noted in your diary to share with your care team."
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
    reject_simulated_inputs(simulated_sam_masks=payload.simulated_sam_masks)
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
    reject_simulated_inputs(
        simulated_letter_heights_px=payload.simulated_letter_heights_px,
        simulated_sam_decay_pct=payload.simulated_sam_decay_pct,
    )
    res = analyze_handwriting_opencv(
        image_bytes=img_bytes,
        simulated_letter_heights_px=payload.simulated_letter_heights_px,
        simulated_sam_decay_pct=payload.simulated_sam_decay_pct,
    )

    if not res["measured"]:
        return {
            "event_uuid": payload.event_uuid,
            **res,
            "spoken_response": (
                "I couldn't read enough of that line to measure it. "
                "Try again with the whole sentence in frame."
            ),
        }

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

    if not settings.enable_research_metrics:
        res.pop("handwriting_score", None)
        res["micrographia_detected"] = False
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

    dose_ts = await dose_timestamp_at_or_before(auth.patient_id, payload.timestamp_utc)
    minutes_since_dose: Optional[int] = None
    has_dose = False
    if dose_ts:
        try:
            t_exam = datetime.fromisoformat(payload.timestamp_utc.replace("Z", "+00:00"))
            t_dose = datetime.fromisoformat(dose_ts.replace("Z", "+00:00"))
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

    clinical_summary = "Home motor check: " + describe_task_metrics(
        voice_mean_dbfs=payload.voice_mean_dbfs,
        handwriting_decay_pct=payload.handwriting_opencv_decay_pct,
        walk_cadence_spm=payload.walk_cadence_spm,
        walk_fog_count=payload.walk_fog_count,
    ) + "."

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

    if not settings.enable_research_metrics:
        return {"exam_uuid": payload.exam_uuid, "clinical_summary": clinical_summary}
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
    if not settings.enable_research_metrics:
        for exam in exams:
            for key in ("medication_state_label", "voice_score", "handwriting_score", "gait_score", "composite_motor_score"):
                exam.pop(key, None)
    return {"patient_id": auth.patient_id, "exams": exams}


def _within_last_day(timestamp_iso: str) -> bool:
    try:
        when = parse_utc(timestamp_iso)
    except ValueError:
        return False
    return (datetime.now(timezone.utc) - when).total_seconds() <= 24 * 3600


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
    voice_rows = await fetch_all(
        "SELECT * FROM voice_logs WHERE patient_id = ? ORDER BY timestamp_utc DESC LIMIT 100",
        (pid,),
    )
    exam_rows = await fetch_all(
        "SELECT * FROM motor_exams WHERE patient_id = ? ORDER BY timestamp_utc DESC LIMIT 50",
        (pid,),
    )

    timeline = build_24h_diary_timeline(
        fog_rows=fog_rows,
        fall_rows=fall_rows,
        med_rows=med_rows,
        writing_rows=writing_rows,
        voice_rows=voice_rows,
        exam_rows=exam_rows,
    )

    summary_stats = {
        "on_pct": timeline["on_pct"],
        "wearing_off_pct": timeline["wearing_off_pct"],
        "off_pct": timeline["off_pct"],
        "no_dose_pct": timeline["no_dose_pct"],
        "fog_count": len(fog_rows),
        # Confirmed falls drive the clinical headline; cancelled and suppressed
        # candidates are reported separately so a neurologist can still see that
        # the detector fired and the patient resolved it, rather than the event
        # vanishing from the report entirely.
        "fall_count": len(
            [
                f
                for f in fall_rows
                if f.get("status") not in {"canceled_false_alarm", "suppressed_unworn_drop"}
            ]
        ),
        "fall_candidate_resolved_count": len(
            [f for f in fall_rows if f.get("status") == "canceled_false_alarm"]
        ),
        "fall_suppressed_count": len(
            [f for f in fall_rows if f.get("status") == "suppressed_unworn_drop"]
        ),
        "latest_exam_score": exam_rows[0]["composite_motor_score"] if exam_rows else None,
        "exam_on_vs_off_delta": timeline["exam_on_vs_off_delta"],
        "dose_count": len(
            [
                m
                for m in med_rows
                if m.get("event_type") == "dose_taken"
                and _within_last_day(str(m.get("timestamp_utc", "")))
            ]
        ),
        "latest_exam_metrics": (
            {
                "voice_mean_dbfs": exam_rows[0]["voice_mean_dbfs"],
                "handwriting_opencv_decay_pct": exam_rows[0]["handwriting_opencv_decay_pct"],
                "walk_cadence_spm": exam_rows[0]["walk_cadence_spm"],
                "walk_fog_count": exam_rows[0]["walk_fog_count"],
            }
            if exam_rows
            else None
        ),
    }
    narrative = None
    if settings.fireworks_api_key:
        narrative = await fireworks_client.summarize_clinical_diary(summary_stats)
    if not narrative:
        narrative = await baseten_client.summarize_clinical_diary(summary_stats)

    if not settings.enable_research_metrics:
        for key in ("on_pct", "wearing_off_pct", "off_pct", "no_dose_pct", "latest_exam_score", "exam_on_vs_off_delta"):
            summary_stats.pop(key, None)
        hidden = {"medication_state_label", "voice_score", "handwriting_score", "gait_score",
                  "composite_motor_score", "estimated_protein_grams", "conflict_detected",
                  "micrographia_detected"}
        for rows in (exam_rows, med_rows, writing_rows):
            for row in rows:
                for key in hidden:
                    row.pop(key, None)
        for bucket in timeline["buckets"]:
            for key in ("clinical_state", "symptom_burden_score", "exam_composite_score", "protein_conflict_active"):
                bucket.pop(key, None)
    return {
        "patient_id": pid,
        "summary_stats": summary_stats,
        "buckets_24h": timeline["buckets"],
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


@app.post("/api/v1/demo/seed", dependencies=[Depends(require_demo_mode)])
async def seed_demo_patient_timeline(
    auth: AuthContext = Depends(require_device_writer),
) -> Dict[str, Any]:
    """
    Populates a complete, clinically realistic 24-hour Parkinson's patient timeline:

      07:30 Morning OFF Home Motor Exam    12:50 Steak high-protein conflict
      08:00 Morning Levodopa dose          14:00 Post-meal FoG + micrographia
      09:15 Peak ON Home Motor Exam        16:15 Hallucination reality check
      11:30 Wearing-off FoG episode        16:20 Hypophonia voice nudge
      12:30 Midday Levodopa dose           17:30 Evening Levodopa dose
                                           17:45 Fall, resolved on check-in
                                           19:30 End-of-day OFF Home Motor Exam

    The 17:45 fall is seeded already resolved ('canceled_false_alarm') so
    re-running the demo never places a live Twilio call.
    """
    pid = auth.patient_id
    # 1. Morning OFF Home Motor Exam (07:30 UTC)
    off_exam = HomeMotorExamCreate(
        exam_uuid="demo-exam-morning-off-001",
        timestamp_utc="2026-10-26T07:30:00Z",
        voice_mean_dbfs=-25.5,
        voice_stability_db=3.8,
        handwriting_opencv_decay_pct=-31.0,
        handwriting_sam_decay_pct=-29.5,
        walk_cadence_spm=68.0,
        walk_mean_fi=2.95,
        walk_fog_count=2,
    )
    await complete_home_motor_exam(
        off_exam, AuthContext(role="device_writer", patient_id=pid)
    )

    # 2. 08:00 UTC Morning Levodopa Dose
    await log_medication_dose(
        DoseLogCreate(
            event_uuid="demo-med-dose-0800",
            timestamp_utc="2026-10-26T08:00:00Z",
        ),
        AuthContext(role="device_writer", patient_id=pid),
    )

    # 3. 09:15 UTC Peak ON Home Motor Exam (75 min post-dose)
    on_exam = HomeMotorExamCreate(
        exam_uuid="demo-exam-morning-on-002",
        timestamp_utc="2026-10-26T09:15:00Z",
        voice_mean_dbfs=-15.2,
        voice_stability_db=1.1,
        handwriting_opencv_decay_pct=-6.4,
        handwriting_sam_decay_pct=-5.8,
        walk_cadence_spm=106.0,
        walk_mean_fi=0.72,
        walk_fog_count=0,
    )
    await complete_home_motor_exam(
        on_exam, AuthContext(role="device_writer", patient_id=pid)
    )

    # 4. 11:30 UTC End-of-Dose WEARING-OFF FoG Episode
    await log_fog_event(
        FoGEventCreate(
            event_uuid="demo-fog-1130",
            timestamp_utc="2026-10-26T11:30:00Z",
            duration_sec=5.5,
            peak_freeze_index=2.45,
            locomotor_band_power=0.12,
            freeze_band_power=0.294,
            sampled_hz=100.0,
            arming_mode="turning_upright",
            cue_bpm=98,
            recovery_latency_sec=3.2,
        ),
        AuthContext(role="device_writer", patient_id=pid),
    )

    # 5. 12:30 UTC Midday Levodopa Dose + 12:50 UTC High-Protein Steak Meal (Conflict)
    await log_medication_dose(
        DoseLogCreate(
            event_uuid="demo-med-dose-1230",
            timestamp_utc="2026-10-26T12:30:00Z",
        ),
        AuthContext(role="device_writer", patient_id=pid),
    )
    await analyze_meal_protein(
        MealProteinAnalyzeRequest(
            event_uuid="demo-meal-steak-1250",
            timestamp_utc="2026-10-26T12:50:00Z",
            simulated_masks=[
                {"label": "steak", "area_px": 34000.0, "confidence": 0.94},
                {"label": "plate", "area_px": 72000.0, "confidence": 0.98},
            ],
        ),
        AuthContext(role="device_writer", patient_id=pid),
    )

    # 6. 14:00 UTC Delayed-Absorption OFF Episode (FoG + Micrographia)
    await log_fog_event(
        FoGEventCreate(
            event_uuid="demo-fog-1400",
            timestamp_utc="2026-10-26T14:00:00Z",
            duration_sec=7.0,
            peak_freeze_index=3.25,
            locomotor_band_power=0.10,
            freeze_band_power=0.325,
            sampled_hz=100.0,
            arming_mode="sit_to_stand",
            cue_bpm=100,
            recovery_latency_sec=4.1,
        ),
        AuthContext(role="device_writer", patient_id=pid),
    )
    await analyze_handwriting_endpoint(
        HandwritingAnalyzeRequest(
            event_uuid="demo-writing-1405",
            timestamp_utc="2026-10-26T14:05:00Z",
            simulated_letter_heights_px=[42.0, 40.0, 38.0, 33.0, 29.0, 27.0],
            simulated_sam_decay_pct=-27.8,
            source_context="ambient",
        ),
        AuthContext(role="device_writer", patient_id=pid),
    )

    # 7. 16:15 UTC Hallucination Reality Check
    await reality_check_endpoint(
        RealityCheckRequest(
            event_uuid="demo-reality-1615",
            timestamp_utc="2026-10-26T16:15:00Z",
            user_query="Is someone standing by the coat rack?",
            simulated_sam_masks=[
                {"label": "coat rack", "confidence": 0.93, "area_ratio": 0.24}
            ],
        ),
        AuthContext(role="device_writer", patient_id=pid),
    )

    # 8. 16:20 UTC Evening Hypophonia Nudge (quiet speech below the -24 dBFS baseline)
    await log_voice_event(
        VoiceLogCreate(
            event_uuid="demo-voice-1620",
            timestamp_utc="2026-10-26T16:20:00Z",
            window_mean_dbfs=-34.5,
            baseline_dbfs=-24.0,
            nudge_triggered=True,
        ),
        AuthContext(role="device_writer", patient_id=pid),
    )

    # 9. 17:30 UTC Evening Levodopa Dose
    await log_medication_dose(
        DoseLogCreate(
            event_uuid="demo-med-dose-1730",
            timestamp_utc="2026-10-26T17:30:00Z",
        ),
        AuthContext(role="device_writer", patient_id=pid),
    )

    # 10. 17:45 UTC Fall with a resolved voice check-in.
    # Seeded directly as 'canceled_false_alarm' so replaying the demo never
    # places a real Twilio call or starts a 15-minute retry loop; the row still
    # exercises the fall table, the GPS columns and the dashboard's fall panel.
    await fall_escalation_manager.ingest_fall_event(
        patient_id=pid,
        payload=FallEventCreate(
            event_uuid="demo-fall-1745",
            timestamp_utc="2026-10-26T17:45:00Z",
            peak_impact_g=3.4,
            peak_jerk_gs=41.0,
            post_impact_tilt_deg=68.0,
            pre_impact_wear_rms_g=0.07,
            pre_impact_resp_power=2.1e-5,
            worn_pre_impact=True,
            latitude=37.774900,
            longitude=-122.419400,
            horizontal_accuracy_m=5.0,
            status="canceled_false_alarm",
            cancel_transcript="i'm okay, i just sat down hard",
            local_siren_activated=False,
        ),
        start_background_retry=False,
    )

    # 11. 19:30 UTC End-of-Day OFF Home Motor Exam (120 min after the evening dose)
    evening_exam = HomeMotorExamCreate(
        exam_uuid="demo-exam-evening-off-003",
        timestamp_utc="2026-10-26T19:30:00Z",
        voice_mean_dbfs=-27.0,
        voice_stability_db=3.1,
        handwriting_opencv_decay_pct=-24.0,
        handwriting_sam_decay_pct=-22.5,
        walk_cadence_spm=81.0,
        walk_mean_fi=1.95,
        walk_fog_count=1,
    )
    await complete_home_motor_exam(
        evening_exam, AuthContext(role="device_writer", patient_id=pid)
    )

    return {"status": "seeded", "patient_id": pid}
