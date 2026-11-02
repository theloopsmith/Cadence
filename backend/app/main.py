import logging
import asyncio
import base64
import io
import wave
from contextlib import asynccontextmanager
from datetime import datetime, timedelta, timezone
import json
import secrets
from pathlib import Path
from typing import Any, Dict, Optional

from fastapi import Depends, FastAPI, HTTPException, Query, Request, status
from fastapi.responses import FileResponse, HTMLResponse, Response

from app.clients.circuit_breaker import RequestDeadlineContext
from app.clients.meta_models import check_in_keywords, dose_keywords, meta_client
from app.config import settings
from app.db import (
    execute_patient_write,
    data_generation_sync,
    record_dose_retraction,
    fetch_all,
    fetch_one,
    init_db,
    purge_expired_telemetry,
    wipe_patient_data,
)
from app.models import (
    MAX_IMAGE_BASE64_LENGTH,
    CompanionInterpretRequest,
    DoseLogCreate,
    DoseRetractionCreate,
    FallEventCreate,
    FoGEventCreate,
    HandwritingAnalyzeRequest,
    HomeMotorExamCreate,
    LoginRequest,
    SpeechTranscribeRequest,
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
from app.responses import observation_projection, ExamHistoryResponse, NeurologistReportResponse, RealityCheckResponse, DroppedEventResponse
from app.rate_limit import consume_inference, require_metered_writer
from app.errors import install_error_handlers
from app.services.dose_clock import parse_utc
from app.services.plain_language import describe_task_metrics
from app.services.diary_engine import build_24h_diary_timeline
from app.services.fall_escalation import fall_escalation_manager
from app.services.handwriting import analyze_handwriting_opencv, handwriting_response
from app.services.exam_validity import measured_exam
from app.services.report_snapshot import report_snapshot
from app.services.plain_language import summarize_day
from app.services.reality_check import run_reality_check_pipeline


@asynccontextmanager
async def lifespan(app: FastAPI):
    validate_security_settings()
    if settings.static_tokens_enabled and not settings.public_webhook_base_url.startswith(("http://localhost", "http://127.0.0.1")):
        logging.getLogger("cadence").warning(
            "Shared development bearer tokens are enabled while PUBLIC_WEBHOOK_BASE_URL is %s. "
            "Use account sign-in and ALLOW_STATIC_TOKENS=false for LAN access.",
            settings.public_webhook_base_url,
        )
    await init_db()
    await purge_expired_telemetry()
    await fall_escalation_manager.resume_open_escalations()
    yield
    await fall_escalation_manager.close()


app = FastAPI(
    title="Cadence Accessibility Companion API",
    version="1.0.0",
    lifespan=lifespan,
    docs_url=None if settings.is_production or settings.cadence_env == "public_demo" else "/docs",
    redoc_url=None if settings.is_production or settings.cadence_env == "public_demo" else "/redoc",
    openapi_url=None if settings.is_production or settings.cadence_env == "public_demo" else "/openapi.json",
)
install_error_handlers(app)

STATIC_DIR = Path(__file__).parent / "static"


@app.get("/health")
async def health_check() -> Dict[str, str]:
    return {"status": "ok", "service": "cadence-accessibility-companion", "version": "1.0.0"}


@app.get('/api/v1/device/connection')
async def device_connection(
    auth: AuthContext = Depends(require_device_writer),
    include_wipe_status: bool = Query(False),
):
    identity = await fetch_one('SELECT server_id FROM server_identity WHERE singleton=1')
    data = {
        'service': 'cadence-accessibility-companion',
        'server_id': identity['server_id'],
        'patient_id': auth.patient_id,
        'data_generation': await asyncio.to_thread(data_generation_sync, auth.patient_id),
    }
    if include_wipe_status:
        wipe_row = await fetch_one(
            'SELECT MAX(wiped_at_utc) AS latest_wipe_utc FROM patient_wipes WHERE patient_id = ?',
            (auth.patient_id,),
        )
        data['latest_wipe_utc'] = wipe_row['latest_wipe_utc'] if wipe_row else None
    return data


@app.get("/dashboard", response_class=HTMLResponse)
async def get_neurologist_dashboard_shell() -> HTMLResponse:
    """
    Public HTML shell route (200 OK).
    Prompts for the Clinician/Device Bearer token in-page (stored in sessionStorage;
    never in URL query parameters) and fetches /api/v1/report/neurologist with Authorization header.
    """
    html_path = STATIC_DIR / "neurologist_dashboard.html"
    nonce = secrets.token_urlsafe(24)
    policy = (
        "default-src 'none'; "
        f"script-src 'nonce-{nonce}'; script-src-attr 'none'; "
        "style-src 'self' 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; "
        "font-src 'self'; base-uri 'none'; object-src 'none'; frame-ancestors 'none'; form-action 'self'"
    )
    return HTMLResponse(
        content=html_path.read_text(encoding="utf-8").replace('__CADENCE_SCRIPT_NONCE__', nonce),
        headers={'Content-Security-Policy': policy, 'X-Content-Type-Options': 'nosniff',
                 'Referrer-Policy': 'no-referrer', 'Cache-Control': 'no-store'},
    )


@app.get('/assets/dashboard.js')
async def get_dashboard_script():
    return Response(content=(STATIC_DIR/'dashboard.js').read_text(encoding='utf-8'),
        media_type='text/javascript', headers={'X-Content-Type-Options': 'nosniff', 'Cache-Control': 'no-store'})


@app.get("/walkthrough", response_class=HTMLResponse)
@app.get("/demo", response_class=HTMLResponse)
async def get_smart_glasses_walkthrough_shell() -> HTMLResponse:
    """
    Public, illustrative wearer story. Live backend checks are separately
    authenticated; scrolling the tour never generates patient events.
    """
    html_path = STATIC_DIR / "walkthrough.html"
    nonce = secrets.token_urlsafe(24)
    policy = (
        "default-src 'none'; "
        f"script-src 'nonce-{nonce}'; script-src-attr 'none'; "
        "style-src 'self' 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; "
        "font-src 'self'; base-uri 'none'; object-src 'none'; frame-ancestors 'none'; form-action 'self'"
    )
    return HTMLResponse(
        content=html_path.read_text(encoding="utf-8").replace('__CADENCE_HOW_IT_WORKS__',
            (STATIC_DIR/'how-it-works.html').read_text(encoding='utf-8')).replace('__CADENCE_SCRIPT_NONCE__', nonce),
        headers={'Content-Security-Policy': policy, 'X-Content-Type-Options': 'nosniff',
                 'Referrer-Policy': 'no-referrer', 'Cache-Control': 'no-store'},
    )


@app.get('/assets/walkthrough.js')
async def get_walkthrough_script():
    return Response(content=(STATIC_DIR/'walkthrough.js').read_text(encoding='utf-8'),
        media_type='text/javascript', headers={'X-Content-Type-Options': 'nosniff', 'Cache-Control': 'no-store'})


@app.get('/assets/walkthrough.css')
async def get_walkthrough_styles():
    return Response(content=(STATIC_DIR/'walkthrough.css').read_text(encoding='utf-8'),
        media_type='text/css', headers={'X-Content-Type-Options': 'nosniff', 'Cache-Control': 'no-store'})


@app.get('/assets/how-it-works.css')
async def get_build_styles():
    return Response(content=(STATIC_DIR/'how-it-works.css').read_text(encoding='utf-8'),
        media_type='text/css', headers={'X-Content-Type-Options': 'nosniff', 'Cache-Control': 'no-store'})


@app.get('/assets/how-it-works.js')
async def get_build_script():
    return Response(content=(STATIC_DIR/'how-it-works.js').read_text(encoding='utf-8'),
        media_type='text/javascript', headers={'X-Content-Type-Options': 'nosniff', 'Cache-Control': 'no-store'})


@app.get('/assets/walkthrough/{asset}')
async def get_walkthrough_image(asset: str):
    if asset not in {'wearer.jpg', 'table.jpg', 'desk.jpg', 'hall.jpg', 'coatstand.jpg', 'safety_floor.jpg', 'together.jpg',
                     'motor-voice.jpg', 'writing-first.jpg', 'writing-second.jpg', 'writing-complete.jpg',
                     'handwriting-capture.jpg'}:
        raise HTTPException(status_code=404, detail='Image not found')
    return FileResponse(STATIC_DIR/'walkthrough'/asset, media_type='image/jpeg',
        headers={'X-Content-Type-Options': 'nosniff', 'Cache-Control': 'public, max-age=3600'})


# ==================== SPEECH (Muse Voice Transcribe) ====================
MAX_CLIP_SECONDS = 30
MAX_IMAGE_DECODED_BYTES = 6 * 1024 * 1024   # 6 MB binary image


def _validated_image(image_base64: Optional[str]) -> Optional[bytes]:
    if not image_base64:
        return None
    if len(image_base64) > MAX_IMAGE_BASE64_LENGTH:
        raise HTTPException(
            status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
            detail="Image payload exceeds 10MB limit.",
        )
    try:
        data = base64.b64decode(image_base64, validate=True)
    except Exception:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Invalid base64 encoding for image.",
        )
    if len(data) > MAX_IMAGE_DECODED_BYTES:
        raise HTTPException(
            status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
            detail="Decoded image exceeds 6MB limit.",
        )
    return data


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
    request: Request,
    auth: AuthContext = Depends(require_device_writer),
) -> Dict[str, Any]:
    """Second listener next to the phone's on-device recognizer. Audio is not stored."""
    consume_inference(request, auth, urgent=payload.purpose == "fall_check_in")
    wav_bytes = _validated_wav(payload.audio_base64)
    extra = [k.strip()[:40] for k in payload.keywords if k.strip()]
    base = check_in_keywords() if payload.purpose == "fall_check_in" else dose_keywords()
    if payload.purpose == "companion":
        base = ["Cadence", "motor check", "surroundings", "medication", "caregiver", "capture", "cancel"]
    keywords = list(dict.fromkeys(base + extra))
    result = await meta_client.transcribe_muse_voice(wav_bytes, keywords=keywords)
    return {
        "available": result["available"],
        "transcript": result["transcript"],
        "source": "muse_voice_transcribe",
    }


@app.post("/api/v1/companion/interpret")
async def interpret_companion(
    payload: CompanionInterpretRequest,
    auth: AuthContext = Depends(require_metered_writer),
) -> Dict[str, Any]:
    from app.services.companion import interpret
    return await interpret(payload.text, payload.history)


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


async def check_event_wiped(patient_id: str, timestamp_utc: Optional[str], generation: int = 0) -> bool:
    if generation > 0 or not timestamp_utc:
        return False
    row = await fetch_one(
        "SELECT MAX(wiped_at_utc) AS latest_wipe FROM patient_wipes WHERE patient_id = ?",
        (patient_id,),
    )
    if row and row["latest_wipe"]:
        try: return parse_utc(timestamp_utc) <= parse_utc(row["latest_wipe"])
        except (ValueError, TypeError): return True
    return False


# ==================== PIPELINE 1: FREEZING OF GAIT (FoG) ====================
@app.post("/api/v1/events/fog")
async def log_fog_event(
    payload: FoGEventCreate,
    auth: AuthContext = Depends(require_device_writer),
) -> Dict[str, Any]:
    if await check_event_wiped(auth.patient_id, payload.timestamp_utc, auth.data_generation):
        return {"status": "dropped_wiped", "event_uuid": payload.event_uuid}
    await execute_patient_write(auth,
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
    if await check_event_wiped(auth.patient_id, payload.timestamp_utc, auth.data_generation):
        return {"status": "dropped_wiped", "event_uuid": payload.event_uuid}
    result = await fall_escalation_manager.ingest_fall_event(
        patient_id=auth.patient_id,
        payload=payload,
        start_background_retry=True,
        data_generation=auth.data_generation,
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
        data_generation=auth.data_generation,
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
    if await check_event_wiped(auth.patient_id, payload.timestamp_utc, auth.data_generation):
        return {"status": "dropped_wiped", "event_uuid": payload.event_uuid}
    retracted = await fetch_one(
        "SELECT 1 FROM medication_retractions WHERE patient_id = ? AND retracted_event_uuid = ?",
        (auth.patient_id, payload.event_uuid),
    )
    if retracted:
        return {
            "status": "retracted_ignored",
            "event_uuid": payload.event_uuid,
            "detail": "Dose was already retracted by user undo",
        }
    changed = await execute_patient_write(auth,
        """
        INSERT INTO medication_logs (
            patient_id, event_uuid, timestamp_utc, event_type,
            medication_name, scheduled_time_utc
        ) SELECT ?, ?, ?, 'dose_taken', ?, ?
        WHERE NOT EXISTS (SELECT 1 FROM medication_retractions WHERE patient_id=? AND retracted_event_uuid=?)
        ON CONFLICT(event_uuid) DO NOTHING
        """,
        (
            auth.patient_id,
            payload.event_uuid,
            payload.timestamp_utc,
            payload.medication_name,
            payload.scheduled_time_utc or payload.timestamp_utc,
            auth.patient_id, payload.event_uuid,
        ),
    )
    if not changed:
        if await fetch_one('SELECT 1 FROM medication_retractions WHERE patient_id=? AND retracted_event_uuid=?', (auth.patient_id,payload.event_uuid)):
            return {"status": "retracted_ignored", "event_uuid": payload.event_uuid}
        existing = await fetch_one('SELECT patient_id FROM medication_logs WHERE event_uuid=?', (payload.event_uuid,))
        if existing and existing['patient_id'] != auth.patient_id: raise HTTPException(404, 'Dose not found.')
    return {"status": "logged", "event_uuid": payload.event_uuid, "event_type": "dose_taken"}


@app.post("/api/v1/medication/dose/retract")
async def retract_medication_dose(
    payload: DoseRetractionCreate,
    auth: AuthContext = Depends(require_device_writer),
) -> Dict[str, Any]:
    if await check_event_wiped(auth.patient_id, payload.timestamp_utc, auth.data_generation):
        return {
            "status": "dropped_wiped",
            "event_uuid": payload.event_uuid,
            "detail": "Retraction dropped because it predates a patient data reset",
        }
    await record_dose_retraction(auth, payload)
    return {
        "status": "retracted",
        "event_uuid": payload.event_uuid,
        "retracted_event_uuid": payload.retracted_event_uuid,
    }


@app.post("/api/v1/meals/log")
async def log_meal_time(payload: MealLogCreate, auth: AuthContext = Depends(require_device_writer)) -> Dict[str, Any]:
    if await check_event_wiped(auth.patient_id, payload.timestamp_utc, auth.data_generation):
        return {"status": "dropped_wiped", "event_uuid": payload.event_uuid}
    await execute_patient_write(auth,
        """INSERT INTO medication_logs (patient_id, event_uuid, timestamp_utc, event_type)
           VALUES (?, ?, ?, 'meal_logged') ON CONFLICT(event_uuid) DO NOTHING""",
        (auth.patient_id, payload.event_uuid, payload.timestamp_utc),
    )
    return {"event_uuid": payload.event_uuid, "timestamp_utc": payload.timestamp_utc,
            "spoken_response": "Meal time logged in your routine diary."}


# ==================== PIPELINE 4: BOUNDED PHOTO OBSERVATIONS ====================
@app.post("/api/v1/reality-check", response_model=RealityCheckResponse | DroppedEventResponse, response_model_exclude_unset=True)
async def reality_check_endpoint(
    payload: RealityCheckRequest,
    auth: AuthContext = Depends(require_metered_writer),
) -> Dict[str, Any]:
    if await check_event_wiped(auth.patient_id, payload.timestamp_utc, auth.data_generation):
        return {"status": "dropped_wiped", "event_uuid": payload.event_uuid}
    img_bytes = _validated_image(payload.image_base64)
    reject_simulated_inputs(simulated_sam_masks=payload.simulated_sam_masks)
    deadline = RequestDeadlineContext()
    try:
        async with asyncio.timeout(deadline.remaining_sec()):
            res = await run_reality_check_pipeline(
                user_query=payload.user_query,
                image_bytes=img_bytes,
                simulated_sam_masks=payload.simulated_sam_masks,
                deadline=deadline,
            )
    except TimeoutError:
        raise HTTPException(
            status_code=status.HTTP_504_GATEWAY_TIMEOUT,
            detail="Reality check deadline exhausted across model pipeline.",
        )

    await execute_patient_write(auth,
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
    auth: AuthContext = Depends(require_metered_writer),
) -> Dict[str, Any]:
    if await check_event_wiped(auth.patient_id, payload.timestamp_utc, auth.data_generation):
        return {"status": "dropped_wiped", "event_uuid": payload.event_uuid}
    img_bytes = _validated_image(payload.image_base64)
    reject_simulated_inputs(
        simulated_letter_heights_px=payload.simulated_letter_heights_px,
        simulated_sam_decay_pct=payload.simulated_sam_decay_pct,
    )
    res = await asyncio.to_thread(
        analyze_handwriting_opencv,
        image_bytes=img_bytes,
        simulated_letter_heights_px=payload.simulated_letter_heights_px,
        simulated_sam_decay_pct=payload.simulated_sam_decay_pct,
    )

    if not res["measured"]:
        return handwriting_response({
            "event_uuid": payload.event_uuid,
            **res,
            "spoken_response": (
                "I couldn't read enough of that line to measure it. "
                "Try again with the whole sentence in frame."
            ),
        })

    await execute_patient_write(auth,
        """
        INSERT INTO handwriting_logs (
            patient_id, event_uuid, timestamp_utc, letter_boxes_json,
            initial_stroke_height_px, final_stroke_height_px,
            opencv_cc_decay_pct, sam_3_1_decay_pct,
            deskew_angle_deg, source_context
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
            res["deskew_angle_deg"],
            payload.source_context,
        ),
    )

    shrink = res["opencv_cc_decay_pct"]
    spoken = (
        f"Letters at the end of the line were about {abs(shrink):.0f}% "
        f"{'smaller' if shrink < 0 else 'larger'} than at the start."
        if abs(shrink) >= 5 else "Letter size stayed about the same across the line."
    )
    return handwriting_response({"event_uuid": payload.event_uuid, **res, "spoken_response": spoken})


@app.post("/api/v1/events/voice")
async def log_voice_event(
    payload: VoiceLogCreate,
    auth: AuthContext = Depends(require_device_writer),
) -> Dict[str, Any]:
    if await check_event_wiped(auth.patient_id, payload.timestamp_utc, auth.data_generation):
        return {"status": "dropped_wiped", "event_uuid": payload.event_uuid}
    await execute_patient_write(auth,
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
    if await check_event_wiped(auth.patient_id, payload.timestamp_utc, auth.data_generation):
        return {"status": "dropped_wiped", "exam_uuid": payload.exam_uuid}
    if payload.measurement_source == 'simulated':
        reject_simulated_inputs(simulated_exam=True)
    raw = payload.model_dump()
    values = measured_exam(raw)
    # Historical score/state columns are not populated by new observations.
    minutes_since_dose = None
    clinical_summary = 'Home motor check: ' + describe_task_metrics(
        voice_mean_dbfs=values['voice_mean_dbfs'], handwriting_decay_pct=values['handwriting_opencv_decay_pct'],
        walk_cadence_spm=values['walk_cadence_spm'], walk_fog_count=values['walk_fog_count']) + '.'
    columns = ['patient_id','exam_uuid','timestamp_utc','minutes_since_last_dose',
        'voice_mean_dbfs','voice_stability_db','handwriting_opencv_decay_pct','handwriting_sam_decay_pct',
        'walk_cadence_spm','walk_mean_fi','walk_fog_count',
        'clinical_summary','voice_status','handwriting_status','walk_status','measurement_source']
    row = {**values, 'patient_id': auth.patient_id,
        'minutes_since_last_dose': minutes_since_dose, 'clinical_summary': clinical_summary}
    # Replays return the committed record, not a different summary of a replacement body.
    existing = await fetch_one('SELECT patient_id FROM motor_exams WHERE exam_uuid=?',(payload.exam_uuid,))
    if existing and existing['patient_id'] != auth.patient_id:
        raise HTTPException(404, 'Motor check not found.')
    await execute_patient_write(auth, f"INSERT INTO motor_exams ({','.join(columns)}) VALUES ({','.join('?' for _ in columns)}) ON CONFLICT(exam_uuid) DO NOTHING",
        tuple(row[k] for k in columns))
    stored = await fetch_one('SELECT * FROM motor_exams WHERE exam_uuid=? AND patient_id=?',(payload.exam_uuid,auth.patient_id))
    if not stored: raise HTTPException(404, 'Motor check not found.')
    return _exam_response(stored)


def _exam_response(row):
    result = measured_exam(row)
    result = observation_projection(result)
    result.pop('id', None)
    result.pop('patient_id', None)
    return result


@app.get("/api/v1/exam/history", response_model=ExamHistoryResponse, response_model_exclude_unset=True)
async def get_exam_history(
    auth: AuthContext = Depends(require_any_authenticated_role),
) -> Dict[str, Any]:
    exams = await fetch_all(
        "SELECT * FROM motor_exams WHERE patient_id = ? ORDER BY timestamp_utc DESC LIMIT 50",
        (auth.patient_id,),
    )
    exams = [_exam_response(exam) for exam in exams]
    return {"patient_id": auth.patient_id, "exams": exams}


# ==================== PIPELINE 7: NEUROLOGIST REPORT & PATIENT WIPE ====================
@app.get("/api/v1/report/neurologist", response_model=NeurologistReportResponse, response_model_exclude_unset=True)
async def get_neurologist_report(
    auth: AuthContext = Depends(require_any_authenticated_role),
) -> Dict[str, Any]:
    pid = auth.patient_id
    snapshot = await report_snapshot(pid)
    fog_rows = snapshot['fog_events']; fall_rows = snapshot['fall_events']
    med_rows = snapshot['medication_logs']; reality_rows = snapshot['reality_checks']
    writing_rows = snapshot['handwriting_logs']; voice_rows = snapshot['voice_logs']
    exam_rows = snapshot['motor_exams']
    exam_rows = [measured_exam(exam) for exam in exam_rows]
    timeline = build_24h_diary_timeline(
        fog_rows=fog_rows,
        fall_rows=fall_rows,
        med_rows=med_rows,
        writing_rows=writing_rows,
        voice_rows=voice_rows,
        exam_rows=exam_rows,
        reference_end_utc=snapshot['end'], other_rows=reality_rows,
    )

    summary_stats = {
        "fog_count": len(fog_rows),
        # Confirmed falls drive the clinical headline; cancelled and suppressed
        # candidates are reported separately so a neurologist can still see that
        # the detector fired and the patient resolved it, rather than the event
        # vanishing from the report entirely.
        "fall_count": len(
            [
                f
                for f in fall_rows
                if f.get("status") not in {"canceled_false_alarm", "suppressed_unworn_drop", "candidate_check_in_pending"}
            ]
        ),
        "fall_candidate_resolved_count": len(
            [f for f in fall_rows if f.get("status") == "canceled_false_alarm"]
        ),
        "fall_suppressed_count": len(
            [f for f in fall_rows if f.get("status") == "suppressed_unworn_drop"]
        ),
        "dose_count": len(
            [
                m
                for m in med_rows
                if m.get("event_type") == "dose_taken"
            ]
        ),
        "latest_exam_metrics": (
            {
                "measurement_source": exam_rows[0]["measurement_source"],
                "task_evidence": exam_rows[0]["task_evidence"],
                "voice_mean_dbfs": exam_rows[0]["voice_mean_dbfs"],
                "handwriting_opencv_decay_pct": exam_rows[0]["handwriting_opencv_decay_pct"],
                "walk_cadence_spm": exam_rows[0]["walk_cadence_spm"],
                "walk_fog_count": exam_rows[0]["walk_fog_count"],
            }
            if exam_rows
            else None
        ),
    }
    summary_stats.update({
        'recorded_event_count': sum(len(rows) for rows in (fog_rows,fall_rows,med_rows,reality_rows,writing_rows,voice_rows,exam_rows)),
        'caregiver_provider_accepted_count': sum(f['provider_accepted'] for f in fall_rows),
        'caregiver_acknowledged_count': sum(f['caregiver_acknowledged'] for f in fall_rows),
        'simulated_alert_count': sum(f['simulated'] for f in fall_rows),
        'alert_queued_count': sum(f['contact_state']=='queued' for f in fall_rows),
        'alert_exhausted_count': sum(f['contact_state']=='exhausted' for f in fall_rows),
        'check_in_pending_count': sum(f['contact_state']=='check_in_pending' for f in fall_rows),
    })
    # Delivery wording and report counts are factual; do not ask a model to infer contact.
    narrative = summarize_day(summary_stats)

    # Legacy stored findings never re-enter public observations.
    exam_rows = observation_projection(exam_rows)
    med_rows = observation_projection(med_rows)
    writing_rows = observation_projection(writing_rows)
    return {
        "patient_id": pid,
        "report_metadata": {
            "data_generation": snapshot['data_generation'],
            "window_start_utc": snapshot['start'].isoformat(), "window_end_utc": snapshot['end'].isoformat(),
            "generated_at_utc": snapshot['end'].isoformat(), "monitoring_coverage": "unknown",
            "coverage_note": "Recorded events do not establish continuous monitoring. No observations does not mean no events occurred.",
            "latest_event_utc": max((r['timestamp_utc'] for rows in (fog_rows,fall_rows,med_rows,reality_rows,writing_rows,voice_rows,exam_rows) for r in rows), key=parse_utc, default=None),
            "detail_limit": 100,
            "details_truncated": {name: len(rows)>100 for name,rows in [('fog_events',fog_rows),('fall_events',fall_rows),('medication_logs',med_rows),('reality_checks',reality_rows),('handwriting_logs',writing_rows),('motor_exams',exam_rows)]},
        },
        "summary_stats": summary_stats,
        "buckets_24h": timeline["buckets"],
        "clinical_narrative": narrative,
        "motor_exams": exam_rows[:100],
        "fog_events": fog_rows[:100],
        "fall_events": fall_rows[:100],
        "medication_logs": med_rows[:100],
        "reality_checks": reality_rows[:100],
        "handwriting_logs": writing_rows[:100],
    }


@app.delete("/api/v1/patient/data")
async def delete_patient_data(
    auth: AuthContext = Depends(require_device_writer),
) -> Dict[str, Any]:
    deleted_counts = await wipe_patient_data(auth.patient_id)
    wiped_at_utc = deleted_counts.pop("wiped_at_utc", None)
    generation = deleted_counts.pop("data_generation")
    return {
        "status": "wiped",
        "patient_id": auth.patient_id,
        "wiped_at_utc": wiped_at_utc,
        "data_generation": generation,
        "deleted_rows": deleted_counts,
    }


@app.post("/api/v1/demo/seed", dependencies=[Depends(require_demo_mode)])
async def seed_demo_patient_timeline(
    auth: AuthContext = Depends(require_device_writer),
) -> Dict[str, Any]:
    """
    Populates a labeled synthetic day of routine checks, dose/meal timestamps,
    walking events and photo observations. The fall is already resolved so
    re-running the seed never places a caregiver call.
    """
    pid = auth.patient_id
    seed_base = datetime.now(timezone.utc) - timedelta(hours=21)
    def demo_time(hour,minute):
        return (seed_base+timedelta(hours=hour,minutes=minute)).isoformat()
    # 1. Morning sample motor check (07:30 UTC)
    off_exam = HomeMotorExamCreate(
        voice_status='measured', handwriting_status='measured', walk_status='measured', measurement_source='simulated',
        exam_uuid="demo-exam-morning-off-001",
        timestamp_utc=demo_time(7,30),
        voice_mean_dbfs=-25.5,
        voice_stability_db=3.8,
        handwriting_opencv_decay_pct=-31.0,
        handwriting_sam_decay_pct=-29.5,
        walk_cadence_spm=68.0,
        walk_mean_fi=2.95,
        walk_fog_count=2,
    )
    await complete_home_motor_exam(
        off_exam, auth
    )

    # 2. 08:00 UTC Morning Levodopa Dose
    await log_medication_dose(
        DoseLogCreate(
            event_uuid="demo-med-dose-0800",
            timestamp_utc=demo_time(8,0),
        ),
        auth,
    )

    # 3. 09:15 UTC Later sample motor check
    on_exam = HomeMotorExamCreate(
        voice_status='measured', handwriting_status='measured', walk_status='measured', measurement_source='simulated',
        exam_uuid="demo-exam-morning-on-002",
        timestamp_utc=demo_time(9,15),
        voice_mean_dbfs=-15.2,
        voice_stability_db=1.1,
        handwriting_opencv_decay_pct=-6.4,
        handwriting_sam_decay_pct=-5.8,
        walk_cadence_spm=106.0,
        walk_mean_fi=0.72,
        walk_fog_count=0,
    )
    await complete_home_motor_exam(
        on_exam, auth
    )

    # 4. 11:30 UTC Sample walking event
    await log_fog_event(
        FoGEventCreate(
            event_uuid="demo-fog-1130",
            timestamp_utc=demo_time(11,30),
            duration_sec=5.5,
            peak_freeze_index=2.45,
            locomotor_band_power=0.12,
            freeze_band_power=0.294,
            sampled_hz=100.0,
            arming_mode="turning_upright",
            cue_bpm=98,
            recovery_latency_sec=3.2,
        ),
        auth,
    )

    # 5. 12:30 UTC Midday dose and meal time
    await log_medication_dose(
        DoseLogCreate(
            event_uuid="demo-med-dose-1230",
            timestamp_utc=demo_time(12,30),
        ),
        auth,
    )
    await log_meal_time(MealLogCreate(event_uuid="demo-meal-1250", timestamp_utc=demo_time(12,50)), auth)

    # 6. 14:00 UTC Walking and writing sample observations
    await log_fog_event(
        FoGEventCreate(
            event_uuid="demo-fog-1400",
            timestamp_utc=demo_time(14,0),
            duration_sec=7.0,
            peak_freeze_index=3.25,
            locomotor_band_power=0.10,
            freeze_band_power=0.325,
            sampled_hz=100.0,
            arming_mode="sit_to_stand",
            cue_bpm=100,
            recovery_latency_sec=4.1,
        ),
        auth,
    )
    await analyze_handwriting_endpoint(
        HandwritingAnalyzeRequest(
            event_uuid="demo-writing-1405",
            timestamp_utc=demo_time(14,5),
            simulated_letter_heights_px=[42.0, 40.0, 38.0, 33.0, 29.0, 27.0],
            simulated_sam_decay_pct=-27.8,
            source_context="ambient",
        ),
        auth,
    )

    # 7. 16:15 UTC Hallucination Reality Check
    await reality_check_endpoint(
        RealityCheckRequest(
            event_uuid="demo-reality-1615",
            timestamp_utc=demo_time(16,15),
            user_query="Is someone standing by the coat rack?",
            simulated_sam_masks=[
                {"label": "coat rack", "confidence": 0.93, "area_ratio": 0.24}
            ],
        ),
        auth,
    )

    # 8. 16:20 UTC Evening Hypophonia Nudge (quiet speech below the -24 dBFS baseline)
    await log_voice_event(
        VoiceLogCreate(
            event_uuid="demo-voice-1620",
            timestamp_utc=demo_time(16,20),
            window_mean_dbfs=-34.5,
            baseline_dbfs=-24.0,
            nudge_triggered=True,
        ),
        auth,
    )

    # 9. 17:30 UTC Evening Levodopa Dose
    await log_medication_dose(
        DoseLogCreate(
            event_uuid="demo-med-dose-1730",
            timestamp_utc=demo_time(17,30),
        ),
        auth,
    )

    # 10. 17:45 UTC Fall with a resolved voice check-in.
    # Seeded directly as 'canceled_false_alarm' so replaying the demo never
    # places a real Twilio call or starts a 15-minute retry loop; the row still
    # exercises the fall table, the GPS columns and the dashboard's fall panel.
    await fall_escalation_manager.ingest_fall_event(
        patient_id=pid,
        payload=FallEventCreate(
            event_uuid="demo-fall-1745",
            timestamp_utc=demo_time(17,45),
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
        data_generation=auth.data_generation,
    )

    # 11. 19:30 UTC Evening sample motor check
    evening_exam = HomeMotorExamCreate(
        voice_status='measured', handwriting_status='measured', walk_status='measured', measurement_source='simulated',
        exam_uuid="demo-exam-evening-off-003",
        timestamp_utc=demo_time(19,30),
        voice_mean_dbfs=-27.0,
        voice_stability_db=3.1,
        handwriting_opencv_decay_pct=-24.0,
        handwriting_sam_decay_pct=-22.5,
        walk_cadence_spm=81.0,
        walk_mean_fi=1.95,
        walk_fog_count=1,
    )
    await complete_home_motor_exam(
        evening_exam, auth
    )

    return {"status": "seeded", "patient_id": pid}
