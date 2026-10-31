import pytest
from app.config import settings


@pytest.fixture(autouse=True)
def default_test_settings(monkeypatch, tmp_path):
    """
    Ensures unit and regression tests run in deterministic simulated mode
    by default, so they do not make real outbound phone calls or network
    calls unless a test explicitly configures credentials.
    """
    monkeypatch.setattr(settings, "enable_research_metrics", True)
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
