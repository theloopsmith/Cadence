from datetime import datetime, timezone
from typing import Any, Dict, List, Literal, Optional
from pydantic import BaseModel, Field


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


class SpeechTranscribeRequest(BaseModel):
    """A short clip from the phone's microphone. Transcribed and discarded."""

    audio_base64: str = Field(..., min_length=4, max_length=3_000_000)
    purpose: Literal["fall_check_in", "dose"]
    keywords: List[str] = Field(default_factory=list, max_length=10)


class LoginRequest(BaseModel):
    username: str = Field(..., min_length=1, max_length=128)
    password: str = Field(..., min_length=1, max_length=256)


class FoGEventCreate(BaseModel):
    event_uuid: str = Field(..., min_length=4)
    timestamp_utc: str = Field(default_factory=utc_now_iso)
    duration_sec: float = Field(..., ge=0.0)
    peak_freeze_index: float = Field(..., ge=0.0)
    locomotor_band_power: float = Field(..., ge=0.0)
    freeze_band_power: float = Field(..., ge=0.0)
    sampled_hz: float = Field(default=50.0, gt=0.0)
    arming_mode: Literal["walking", "sit_to_stand", "turning_upright"] = "walking"
    speech_active_modifier: bool = False
    cue_bpm: int = Field(default=100, ge=40, le=200)
    recovery_latency_sec: Optional[float] = None


class FallEventCreate(BaseModel):
    event_uuid: str = Field(..., min_length=4)
    timestamp_utc: str = Field(default_factory=utc_now_iso)
    peak_impact_g: float = Field(..., ge=0.0)
    peak_jerk_gs: float = Field(..., ge=0.0)
    post_impact_tilt_deg: float = Field(..., ge=0.0)
    pre_impact_wear_rms_g: float = Field(default=0.05, ge=0.0)
    pre_impact_resp_power: float = Field(default=0.0, ge=0.0)
    worn_pre_impact: bool = True
    vocal_activity_detected: bool = False
    distress_keyword_detected: bool = False
    latitude: Optional[float] = None
    longitude: Optional[float] = None
    horizontal_accuracy_m: Optional[float] = None
    status: Literal[
        "candidate_check_in_pending",
        "canceled_false_alarm",
        "confirmed_waiting_dispatch",
        "escalated_twilio",
        "local_siren_only",
        "suppressed_unworn_drop",
    ] = "confirmed_waiting_dispatch"
    cancel_transcript: Optional[str] = None
    local_siren_activated: bool = True


class DoseLogCreate(BaseModel):
    event_uuid: str = Field(..., min_length=4)
    timestamp_utc: str = Field(default_factory=utc_now_iso)
    medication_name: str = "Levodopa/Carbidopa"
    scheduled_time_utc: Optional[str] = None


class MealProteinAnalyzeRequest(BaseModel):
    event_uuid: str = Field(..., min_length=4)
    timestamp_utc: str = Field(default_factory=utc_now_iso)
    image_base64: Optional[str] = None
    simulated_masks: Optional[List[Dict[str, Any]]] = None


class RealityCheckRequest(BaseModel):
    event_uuid: str = Field(..., min_length=4)
    timestamp_utc: str = Field(default_factory=utc_now_iso)
    user_query: str = Field(..., min_length=2)
    image_base64: Optional[str] = None
    simulated_sam_masks: Optional[List[Dict[str, Any]]] = None


class HandwritingAnalyzeRequest(BaseModel):
    event_uuid: str = Field(..., min_length=4)
    timestamp_utc: str = Field(default_factory=utc_now_iso)
    image_base64: Optional[str] = None
    simulated_letter_heights_px: Optional[List[float]] = None
    simulated_sam_decay_pct: Optional[float] = None
    source_context: Literal["ambient", "home_motor_exam"] = "ambient"


class HomeMotorExamCreate(BaseModel):
    exam_uuid: str = Field(..., min_length=4)
    timestamp_utc: str = Field(default_factory=utc_now_iso)
    voice_mean_dbfs: float
    voice_stability_db: float = Field(
        ..., description="Std-dev in dB computed strictly over the 5s sustained vowel ('Ahhh')"
    )
    handwriting_opencv_decay_pct: float = Field(
        ..., description="Negative percentage when shrinking (e.g., -35.0 for 35% shrinkage)"
    )
    handwriting_sam_decay_pct: Optional[float] = None
    walk_cadence_spm: float = Field(..., ge=0.0)
    walk_mean_fi: float = Field(..., ge=0.0)
    walk_fog_count: int = Field(default=0, ge=0)


class VoiceLogCreate(BaseModel):
    event_uuid: str = Field(..., min_length=4)
    timestamp_utc: str = Field(default_factory=utc_now_iso)
    window_mean_dbfs: float
    baseline_dbfs: float = -24.0
    nudge_triggered: bool = False
