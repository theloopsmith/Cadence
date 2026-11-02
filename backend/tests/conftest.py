import os

# Explicit test-only credentials, installed before modules build request headers.
os.environ["CADENCE_DEVICE_TOKEN"] = "cadence-dev-device-writer-token-2026"
os.environ["CADENCE_CLINICIAN_TOKEN"] = "cadence-dev-clinician-reader-token-2026"

import pytest
from app.config import settings


@pytest.fixture(autouse=True)
def default_test_settings(monkeypatch, tmp_path):
    """
    Ensures unit and regression tests run in deterministic simulated mode
    by default, so they do not make real outbound phone calls or network
    calls unless a test explicitly configures credentials.
    """
    monkeypatch.setattr(settings, "cadence_env", "test")
    monkeypatch.setattr(settings, "allow_static_tokens", None)
    monkeypatch.setattr(settings, "cadence_device_token", "cadence-dev-device-writer-token-2026")
    monkeypatch.setattr(settings, "cadence_clinician_token", "cadence-dev-clinician-reader-token-2026")
    from app import rate_limit
    monkeypatch.setattr(rate_limit, "inference_quota", rate_limit.InferenceQuota())
    monkeypatch.setattr(settings, "twilio_account_sid", "")
    monkeypatch.setattr(settings, "twilio_auth_token", "")
    monkeypatch.setattr(settings, "twilio_from_phone", "")
    monkeypatch.setattr(settings, "fireworks_api_key", "")
    monkeypatch.setattr(settings, "baseten_api_key", "")
    monkeypatch.setattr(settings, "meta_api_key", "")
    # Wipe generations are durable state; one test's erase must not alter the
    # generation expected by another test's independent phone session.
    from app.db import init_db_sync
    monkeypatch.setattr(settings, 'sqlite_db_path', str(tmp_path / 'isolated-test.db'))
    init_db_sync()
