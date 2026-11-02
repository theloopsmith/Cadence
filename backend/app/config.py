from pathlib import Path
from datetime import datetime, timezone
from typing import Optional

from pydantic import Field, field_validator

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Centralized configuration for Cadence backend with configurable sponsor model IDs."""

    model_config = SettingsConfigDict(
        env_file=str(Path(__file__).resolve().parent.parent / ".env"),
        env_file_encoding="utf-8",
        extra="ignore",
    )

    # "development" or "production". Production turns off every convenience below
    # unless it is explicitly re-enabled, and refuses to start without a JWT secret.
    cadence_env: str = "development"

    # Login tokens (HS256). Required in production; at least 32 characters.
    jwt_secret: str = ""
    jwt_access_ttl_minutes: int = 720
    # The phone is signed in once by a care partner; a short token would leave
    # falls waiting on the phone every night.
    jwt_device_ttl_days: int = 30
    # Public judging accounts retire at the configured Pacific-date cutoff.
    demo_accounts_expire_at_utc: datetime = datetime(2026, 11, 18, 8, tzinfo=timezone.utc)

    # Optional local-development bearer tokens. No built-in credentials;
    # public demo and production require account sign-in instead.
    allow_static_tokens: Optional[bool] = None
    cadence_device_token: str = ""
    cadence_clinician_token: str = ""
    cadence_default_patient_id: str = "default_patient"

    # Demo seed endpoint and `simulated_*` request fields. Off in production.
    demo_mode: Optional[bool] = None

    @property
    def is_production(self) -> bool:
        return self.cadence_env.strip().lower() == "production"

    @property
    def demo_mode_enabled(self) -> bool:
        return self.demo_mode if self.demo_mode is not None else not self.is_production

    @property
    def static_tokens_enabled(self) -> bool:
        if self.allow_static_tokens is not None:
            return self.allow_static_tokens
        return not self.is_production and bool(self.cadence_device_token or self.cadence_clinician_token)

    @field_validator("demo_accounts_expire_at_utc")
    @classmethod
    def timezone_required_for_judging_expiry(cls, value: datetime) -> datetime:
        if value.tzinfo is None or value.utcoffset() is None:
            raise ValueError("DEMO_ACCOUNTS_EXPIRE_AT_UTC must include a timezone")
        return value.astimezone(timezone.utc)

    # SQLite & Retention
    sqlite_db_path: str = str(Path(__file__).resolve().parent.parent / "cadence_clinical.db")
    # Shared quota across ordinary paid inference routes; process-local, not a billing cap.
    inference_requests_per_minute: int = Field(default=30, ge=1, le=1000)

    @field_validator("sqlite_db_path")
    @classmethod
    def absolute_database_path(cls, value: str) -> str:
        if value == ":memory:":
            return value
        path = Path(value).expanduser()
        if not path.is_absolute():
            path = Path(__file__).resolve().parent.parent / path
        return str(path.resolve())

    sqlite_encryption_key: str = ""
    retention_days: int = 30
    retention_incident_days: int = 365

    # Fireworks AI ($100 Credits)
    fireworks_api_key: str = ""
    fireworks_api_base_url: str = "https://api.fireworks.ai/inference/v1"
    fireworks_llm_model: str = "accounts/fireworks/models/llama-v3p3-70b-instruct"
    fireworks_vlm_model: str = "accounts/fireworks/models/llama-v3p2-11b-vision-instruct"
    fireworks_stage_budget_sec: float = 1.2

    # Meta Model API ($150 Credits)
    meta_api_key: str = ""
    meta_api_base_url: str = "https://api.meta.ai/v1"
    meta_sam_model: str = "sam-3.1"
    meta_stt_model: str = "muse-voice-transcribe-1.0"
    meta_asr_base_url: str = "https://api.meta.ai/v1"

    # Baseten ($100 Credits • 2M TPM)
    baseten_api_key: str = ""
    baseten_api_base_url: str = "https://inference.baseten.co/v1"
    baseten_model: str = "meta-models/muse-spark-open-1026"

    # One interactive request (photo in, sentence out) may use this much wall clock.
    # Measured 2026-10-29: a single live SAM 3.1 call takes 2.5-3.6 s.
    interactive_request_budget_sec: float = 12.0
    sam_stage_budget_sec: float = 6.0
    scene_proposal_budget_sec: float = 7.0
    # Room for Muse reasoning; always clamped by the shared request deadline.
    baseten_stage_budget_sec: float = 3.0

    # Twilio Escalation & Caregiver Contacts
    twilio_account_sid: str = ""
    twilio_auth_token: str = ""
    twilio_api_key_sid: str = ""
    twilio_api_key_secret: str = ""
    twilio_from_phone: str = ""
    caregiver_primary_phone: str = ""
    caregiver_secondary_phone: str = ""
    public_webhook_base_url: str = "http://localhost:8000"
    secondary_escalation_delay_sec: float = 90.0
    retry_interval_sec: float = 60.0
    max_retry_attempts: int = 15
    # Hard wall-clock cap on caregiver call-out, measured from dispatch. The
    # 90s secondary delay is inside this window, so the loop cannot overrun it.
    retry_window_sec: float = 900.0

    dispatch_lease_sec: float = 60.0
    dispatch_timeout_sec: float = 20.0
    # The phone's check-in window is 30 s (FallAlertCoordinator.checkInWindowSec).
    # The server waits longer so a late "I'm okay" upload is not overtaken by a
    # server-side timeout that calls a caregiver anyway.
    fall_check_in_sec: float = 45.0
    recovery_poll_sec: float = 1.0

    # Safety Calibration Gate (Disabled by default until Day-2 supine-vs-table verification)
    enable_unworn_drop_suppression: bool = False


settings = Settings()
