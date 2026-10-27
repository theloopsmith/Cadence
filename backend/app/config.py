from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Centralized configuration for Cadence backend with configurable sponsor model IDs."""

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    # Role-Based Bearer Tokens & Patient Binding
    cadence_device_token: str = "cadence-dev-device-writer-token-2026"
    cadence_clinician_token: str = "cadence-dev-clinician-reader-token-2026"
    cadence_default_patient_id: str = "default_patient"

    # SQLite & Retention
    sqlite_db_path: str = "./cadence_clinical.db"
    sqlite_encryption_key: str = ""
    retention_days: int = 30
    retention_incident_days: int = 365

    # Meta Model API ($150 Credits)
    meta_api_key: str = ""
    meta_api_base_url: str = "https://api.llama.com/v1"
    meta_sam_model: str = "sam-3.1"
    meta_stt_model: str = "muse-transcribe"
    meta_tts_model: str = "muse-voice"

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
    twilio_from_phone: str = ""
    caregiver_primary_phone: str = ""
    caregiver_secondary_phone: str = ""
    public_webhook_base_url: str = "http://localhost:8000"
    secondary_escalation_delay_sec: float = 90.0
    retry_interval_sec: float = 60.0
    max_retry_attempts: int = 15

    # Safety Calibration Gate (Disabled by default until Day-2 supine-vs-table verification)
    enable_unworn_drop_suppression: bool = False


settings = Settings()
