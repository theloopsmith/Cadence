from datetime import datetime, timedelta, timezone
from typing import Annotated, Any, Dict, List, Literal, Optional
from pydantic import AfterValidator, BaseModel, Field, ConfigDict, model_validator


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


# Clock skew a phone may legitimately show; anything further ahead is a bug or forgery.
_FUTURE_GRACE = timedelta(minutes=5)


def _utc_timestamp(value: str) -> str:
    """Parses any ISO-8601 instant, treats a missing zone as UTC, rejects the far future."""
    text = str(value).strip()
    if text.endswith(("Z", "z")):
        text = text[:-1] + "+00:00"
    try:
        when = datetime.fromisoformat(text)
    except ValueError as exc:
        raise ValueError("timestamp_utc must be an ISO-8601 time") from exc
    if when.tzinfo is None:
        when = when.replace(tzinfo=timezone.utc)
    if when > datetime.now(timezone.utc) + _FUTURE_GRACE:
        raise ValueError("timestamp_utc is in the future")
    return when.astimezone(timezone.utc).isoformat()


UtcTimestamp = Annotated[str, AfterValidator(_utc_timestamp)]
MAX_IMAGE_BASE64_LENGTH = 10 * 1024 * 1024  # 10 MB of base64 text


class CadenceModel(BaseModel):
    """Every wire model: NaN/Infinity are not numbers here, unknown keys are dropped."""

    model_config = ConfigDict(allow_inf_nan=False)


class SpeechTranscribeRequest(CadenceModel):
    """A short clip from the phone's microphone. Transcribed and discarded."""

    audio_base64: str = Field(..., min_length=4, max_length=3_000_000)
    purpose: Literal["fall_check_in", "dose", "companion"]
    keywords: List[str] = Field(default_factory=list, max_length=10)


class CompanionInterpretRequest(CadenceModel):
    text: str = Field(..., min_length=1, max_length=1200)
    history: List[Annotated[str, Field(max_length=1200)]] = Field(default_factory=list, max_length=6)


class LoginRequest(CadenceModel):
    username: str = Field(..., min_length=1, max_length=128)
    password: str = Field(..., min_length=1, max_length=256)


class FoGEventCreate(CadenceModel):
    event_uuid: str = Field(..., min_length=4)
    timestamp_utc: UtcTimestamp = Field(default_factory=utc_now_iso)
    duration_sec: float = Field(..., ge=0.0)
    peak_freeze_index: float = Field(..., ge=0.0)
    locomotor_band_power: float = Field(..., ge=0.0)
    freeze_band_power: float = Field(..., ge=0.0)
    sampled_hz: float = Field(default=50.0, gt=0.0)
    arming_mode: Literal["walking", "sit_to_stand", "turning_upright"] = "walking"
    speech_active_modifier: bool = False
    cue_bpm: int = Field(default=100, ge=40, le=200)
    recovery_latency_sec: Optional[float] = None


class FallEventCreate(CadenceModel):
    event_uuid: str = Field(..., min_length=4)
    timestamp_utc: UtcTimestamp = Field(default_factory=utc_now_iso)
    peak_impact_g: float = Field(..., ge=0.0)
    peak_jerk_gs: float = Field(..., ge=0.0)
    post_impact_tilt_deg: float = Field(..., ge=0.0)
    pre_impact_wear_rms_g: float = Field(default=0.05, ge=0.0)
    pre_impact_resp_power: float = Field(default=0.0, ge=0.0)
    worn_pre_impact: bool = True
    vocal_activity_detected: bool = False
    distress_keyword_detected: bool = False
    latitude: Optional[float] = Field(None, ge=-90.0, le=90.0)
    longitude: Optional[float] = Field(None, ge=-180.0, le=180.0)
    horizontal_accuracy_m: Optional[float] = None
    status: Literal[
        "candidate_check_in_pending",
        "canceled_false_alarm",
        "confirmed_waiting_dispatch",
        "escalated_twilio",
        "local_siren_only",
        "suppressed_unworn_drop",
    ] = "confirmed_waiting_dispatch"
    cancel_transcript: Optional[str] = Field(None, max_length=600)
    local_siren_activated: bool = True


class DoseLogCreate(CadenceModel):
    event_uuid: str = Field(..., min_length=4)
    timestamp_utc: UtcTimestamp = Field(default_factory=utc_now_iso)
    medication_name: str = Field("Levodopa/Carbidopa", max_length=120)
    scheduled_time_utc: Optional[str] = None


class DoseRetractionCreate(CadenceModel):
    event_uuid: str = Field(..., min_length=4)
    retracted_event_uuid: str = Field(..., min_length=4)
    timestamp_utc: UtcTimestamp = Field(default_factory=utc_now_iso)
    reason: Optional[str] = "user_undo"


class MealLogCreate(CadenceModel):
    event_uuid: str = Field(..., min_length=4)
    timestamp_utc: UtcTimestamp = Field(default_factory=utc_now_iso)


class MealProteinAnalyzeRequest(CadenceModel):
    event_uuid: str = Field(..., min_length=4)
    timestamp_utc: UtcTimestamp = Field(default_factory=utc_now_iso)
    image_base64: Optional[str] = Field(None, max_length=MAX_IMAGE_BASE64_LENGTH)
    simulated_masks: Optional[List[Dict[str, Any]]] = Field(None, max_length=50)


class RealityCheckRequest(CadenceModel):
    event_uuid: str = Field(..., min_length=4)
    timestamp_utc: UtcTimestamp = Field(default_factory=utc_now_iso)
    user_query: str = Field(..., min_length=2, max_length=400)
    image_base64: Optional[str] = Field(None, max_length=MAX_IMAGE_BASE64_LENGTH)
    simulated_sam_masks: Optional[List[Dict[str, Any]]] = Field(None, max_length=50)


class HandwritingAnalyzeRequest(CadenceModel):
    event_uuid: str = Field(..., min_length=4)
    timestamp_utc: UtcTimestamp = Field(default_factory=utc_now_iso)
    image_base64: Optional[str] = Field(None, max_length=MAX_IMAGE_BASE64_LENGTH)
    simulated_letter_heights_px: Optional[List[float]] = None
    simulated_sam_decay_pct: Optional[float] = None
    source_context: Literal["ambient", "home_motor_exam"] = "ambient"


class HomeMotorExamCreate(CadenceModel):
    model_config = ConfigDict(allow_inf_nan=False)
    exam_uuid: str = Field(..., min_length=4)
    timestamp_utc: UtcTimestamp = Field(default_factory=utc_now_iso)
    voice_status: Literal['measured','skipped','unavailable','legacy_unverified'] = 'legacy_unverified'
    handwriting_status: Literal['measured','skipped','unavailable','legacy_unverified'] = 'legacy_unverified'
    walk_status: Literal['measured','skipped','unavailable','legacy_unverified'] = 'legacy_unverified'
    measurement_source: Literal['device','simulated','legacy_unverified'] = 'legacy_unverified'
    voice_mean_dbfs: Optional[float] = None
    voice_stability_db: Optional[float] = Field(default=None, ge=0)
    handwriting_opencv_decay_pct: Optional[float] = None
    handwriting_sam_decay_pct: Optional[float] = None
    walk_cadence_spm: Optional[float] = Field(default=None, ge=0.0)
    walk_mean_fi: Optional[float] = Field(default=None, ge=0.0)
    walk_fog_count: Optional[int] = Field(default=None, ge=0)

    @model_validator(mode='after')
    def measured_tasks_require_values(self):
        for task, fields in {
            'voice': ('voice_mean_dbfs','voice_stability_db'),
            'handwriting': ('handwriting_opencv_decay_pct',),
            'walk': ('walk_cadence_spm','walk_mean_fi','walk_fog_count'),
        }.items():
            if getattr(self, task+'_status') == 'measured' and any(getattr(self, f) is None for f in fields):
                raise ValueError(f'{task}: measured tasks require all measurements')
        return self


class VoiceLogCreate(CadenceModel):
    event_uuid: str = Field(..., min_length=4)
    timestamp_utc: UtcTimestamp = Field(default_factory=utc_now_iso)
    window_mean_dbfs: float
    baseline_dbfs: float = -24.0
    nudge_triggered: bool = False
