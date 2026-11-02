"""Explicit output contracts. Optional research fields remain absent unless supplied.

These models do not infer measurement from numbers: task status always travels
with reported provenance. Device provenance is a client declaration, not hardware
attestation. Unknown motor/model fields are dropped at the HTTP boundary.
"""
from typing import Any, Literal
from pydantic import BaseModel, ConfigDict, Field, model_validator

from app.config import settings


RESEARCH_FIELDS = {
    "medication_state_label", "clinical_state", "symptom_burden_score", "voice_score",
    "handwriting_score", "gait_score", "composite_motor_score", "exam_composite_score",
    "on_pct", "wearing_off_pct", "off_pct", "no_dose_pct", "unknown_pct",
    "latest_exam_score", "exam_on_vs_off_delta", "estimated_protein_grams",
    "conflict_detected", "protein_conflict_active", "micrographia_detected",
}


def observation_projection(value):
    if isinstance(value, dict):
        return {key: observation_projection(item) for key, item in value.items() if key not in RESEARCH_FIELDS}
    if isinstance(value, list):
        return [observation_projection(item) for item in value]
    return value


class WireResponse(BaseModel):
    model_config = ConfigDict(extra="ignore", allow_inf_nan=False)

    @model_validator(mode="before")
    @classmethod
    def keep_research_out_of_default_outputs(cls, value):
        return value if settings.enable_research_metrics else observation_projection(value)


Source = Literal["device", "simulated", "legacy_unverified"]
TaskStatus = Literal["measured", "skipped", "unavailable", "legacy_unverified"]


class TaskEvidence(WireResponse):
    status: TaskStatus
    measurement_source: Source


class MotorExamResponse(WireResponse):
    exam_uuid: str
    timestamp_utc: str
    measurement_source: Source
    voice_status: TaskStatus
    handwriting_status: TaskStatus
    walk_status: TaskStatus
    task_evidence: dict[Literal["voice", "handwriting", "walk"], TaskEvidence]
    complete: bool
    voice_mean_dbfs: float | None
    voice_stability_db: float | None
    handwriting_opencv_decay_pct: float | None
    handwriting_sam_decay_pct: float | None
    walk_cadence_spm: float | None
    walk_mean_fi: float | None
    walk_fog_count: int | None
    minutes_since_last_dose: int | None
    clinical_summary: str
    # Compatibility for explicitly opted-in, non-public research environments.
    medication_state_label: str | None = None
    voice_score: float | None = None
    handwriting_score: float | None = None
    gait_score: float | None = None
    composite_motor_score: float | None = None


class ExamHistoryResponse(WireResponse):
    patient_id: str
    exams: list[MotorExamResponse]


class LatestExamMetrics(WireResponse):
    measurement_source: Source
    task_evidence: dict[Literal["voice", "handwriting", "walk"], TaskEvidence]
    voice_mean_dbfs: float | None
    handwriting_opencv_decay_pct: float | None
    walk_cadence_spm: float | None
    walk_fog_count: int | None


class SummaryStats(WireResponse):
    fog_count: int
    fall_count: int
    fall_candidate_resolved_count: int
    fall_suppressed_count: int
    dose_count: int
    latest_exam_metrics: LatestExamMetrics | None
    recorded_event_count: int
    caregiver_provider_accepted_count: int
    caregiver_acknowledged_count: int
    simulated_alert_count: int
    alert_queued_count: int
    alert_exhausted_count: int
    check_in_pending_count: int
    on_pct: float | None = None
    wearing_off_pct: float | None = None
    off_pct: float | None = None
    no_dose_pct: float | None = None
    latest_exam_score: float | None = None
    exam_on_vs_off_delta: dict[str, Any] | None = None


class NeurologistReportResponse(WireResponse):
    patient_id: str
    report_metadata: dict[str, Any]
    summary_stats: SummaryStats
    buckets_24h: list[dict[str, Any]]
    clinical_narrative: str
    motor_exams: list[MotorExamResponse]
    fog_events: list[dict[str, Any]]
    fall_events: list[dict[str, Any]]
    medication_logs: list[dict[str, Any]]
    reality_checks: list[dict[str, Any]]
    handwriting_logs: list[dict[str, Any]]


class ModelStageEvidence(WireResponse):
    source: str
    model: str | None
    provider: str | None = None
    latency_ms: int | None = None
    failed_concepts: list[str] = Field(default_factory=list)


class RealityModelEvidence(WireResponse):
    segmentation: ModelStageEvidence
    selection: ModelStageEvidence


class RealityCheckResponse(WireResponse):
    event_uuid: str
    sam_verified: bool
    verified_masks: list[dict[str, Any]]
    living_subject_present: bool
    chosen_inanimate_label: str | None
    template_id: str
    spoken_response: str
    tts_source: Literal["ios_on_device"]
    latency_ms: int
    model_evidence: RealityModelEvidence


class DroppedEventResponse(WireResponse):
    status: Literal["dropped_wiped"]
    event_uuid: str
