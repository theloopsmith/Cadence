from typing import Optional

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Centralized configuration for Cadence backend with configurable sponsor model IDs."""

    model_config = SettingsConfigDict(
        env_file=".env",
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

    # Shared bearer tokens for local development and the demo. Never enabled in
    # production unless CADENCE_ALLOW_STATIC_TOKENS=true is set on purpose.
    allow_static_tokens: Optional[bool] = None
    cadence_device_token: str = "cadence-dev-device-writer-token-2026"
    cadence_clinician_token: str = "cadence-dev-clinician-reader-token-2026"
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
        return not self.is_production

    # SQLite & Retention
    sqlite_db_path: str = "./cadence_clinical.db"
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
    meta_api_base_url: str = "https://api.llama.com/v1"
    meta_sam_model: str = "sam-3.1"
    meta_stt_model: str = "muse-voice-transcribe-1.0"
    meta_asr_base_url: str = "https://api.meta.ai/v1"

    # Baseten ($100 Credits • 2M TPM)
    baseten_api_key: str = ""
    baseten_api_base_url: str = "https://inference.baseten.co/v1"
    baseten_model: str = "meta-models/muse-spark-open-1026"

    # Shared Request Deadline & Per-Stage Budgets
    request_deadline_sec: float = 4.0
    sam_stage_budget_sec: float = 1.8
    baseten_stage_budget_sec: float = 1.2
    tts_stage_budget_sec: float = 0.8

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

    # Safety Calibration Gate (Disabled by default until Day-2 supine-vs-table verification)
    enable_unworn_drop_suppression: bool = False


settings = Settings()
