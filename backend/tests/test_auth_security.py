"""Login, tokens, roles, and the demo-only paths."""

import time
import os
import subprocess
import sys
import threading
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import jwt
import pytest
from fastapi.testclient import TestClient

from app import auth
from app.config import settings
from app.db import execute_write_sync, fetch_one_sync, init_db_sync
from app.main import app


@pytest.fixture
def server(monkeypatch, tmp_path):
    monkeypatch.setattr(settings, "sqlite_db_path", str(tmp_path / "auth.db"))
    monkeypatch.setattr(settings, "jwt_secret", "t" * 48)
    init_db_sync()
    auth.reset_lockouts()
    auth.create_user_sync("dana", "correct horse battery staple", "clinician_reader", "default_patient")
    auth.create_user_sync("phone-1", "device pass phrase long enough", "device_writer", "default_patient")
    with TestClient(app) as client:
        yield client


def _login(client, username, password):
    return client.post("/api/v1/auth/login", json={"username": username, "password": password})


# ---------------------------------------------------------------- passwords
def test_passwords_are_hashed_with_a_salt():
    first = auth.hash_password("correct horse battery staple")
    second = auth.hash_password("correct horse battery staple")
    assert first != second, "each hash gets its own salt"
    assert "correct horse" not in first
    assert first.startswith("scrypt$")
    assert auth.verify_password("correct horse battery staple", first)
    assert not auth.verify_password("Correct horse battery staple", first)
    assert not auth.verify_password("anything", "not-a-hash")


def test_short_passwords_are_refused():
    with pytest.raises(ValueError):
        auth.hash_password("short")


def test_the_stored_row_never_holds_the_password(server):
    row = fetch_one_sync("SELECT password_hash FROM users WHERE username = ?", ("dana",))
    assert "correct horse" not in row["password_hash"]


# ---------------------------------------------------------------- login
def test_login_returns_a_token_that_reads_the_report(server):
    res = _login(server, "dana", "correct horse battery staple")
    assert res.status_code == 200
    body = res.json()
    assert body["token_type"] == "bearer"
    assert body["role"] == "clinician_reader"
    report = server.get(
        "/api/v1/report/neurologist", headers={"Authorization": f"Bearer {body['access_token']}"}
    )
    assert report.status_code == 200


def test_a_clinician_token_cannot_write(server):
    token = _login(server, "dana", "correct horse battery staple").json()["access_token"]
    res = server.post(
        "/api/v1/medication/dose",
        headers={"Authorization": f"Bearer {token}"},
        json={"event_uuid": "dose-clin-1"},
    )
    assert res.status_code == 403


def test_phone_sign_ins_last_longer_than_viewing_sign_ins(server):
    phone = _login(server, "phone-1", "device pass phrase long enough").json()
    viewer = _login(server, "dana", "correct horse battery staple").json()
    assert phone["expires_in"] == settings.jwt_device_ttl_days * 24 * 3600
    assert viewer["expires_in"] == settings.jwt_access_ttl_minutes * 60
    claims = jwt.decode(phone["access_token"], settings.jwt_secret, algorithms=["HS256"])
    assert claims["exp"] - claims["iat"] == phone["expires_in"]


def test_a_device_token_can_write(server):
    token = _login(server, "phone-1", "device pass phrase long enough").json()["access_token"]
    res = server.post(
        "/api/v1/medication/dose",
        headers={"Authorization": f"Bearer {token}"},
        json={"event_uuid": "dose-dev-1"},
    )
    assert res.status_code == 200


def test_wrong_password_and_unknown_user_look_the_same(server):
    wrong = _login(server, "dana", "nope nope nope nope")
    unknown = _login(server, "nobody", "nope nope nope nope")
    assert wrong.status_code == unknown.status_code == 401
    assert wrong.json()["message"] == unknown.json()["message"]
    assert "password" in wrong.json()["message"].lower()


def test_repeated_failures_lock_the_account_for_a_while(server):
    for _ in range(auth.MAX_FAILED_ATTEMPTS):
        assert _login(server, "dana", "wrong wrong wrong").status_code == 401
    locked = _login(server, "dana", "correct horse battery staple")
    assert locked.status_code == 429
    assert "minutes" in locked.json()["message"]


def test_lockout_survives_database_reinitialization_and_fresh_process(server):
    for _ in range(auth.MAX_FAILED_ATTEMPTS):
        with pytest.raises(auth.AuthError):
            auth.authenticate_sync("dana", "wrong")
    init_db_sync()
    script = """
import sys
from app.config import settings
from app import auth
settings.sqlite_db_path = sys.argv[1]
settings.sqlite_encryption_key = ''
try:
    auth.authenticate_sync('dana', 'correct horse battery staple')
except auth.AuthError as error:
    assert error.locked
    print('locked')
else:
    raise AssertionError('restart lost the login budget')
"""
    env = dict(os.environ, PYTHONPATH=str(Path(__file__).resolve().parents[1]))
    result = subprocess.run([sys.executable, "-c", script, settings.sqlite_db_path],
                            env=env, capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "locked"


def test_parallel_logins_cannot_exceed_attempt_budget(server):
    def attempt(_):
        try:
            auth.authenticate_sync("dana", "wrong")
        except auth.AuthError as error:
            return "locked" if error.locked else "wrong"
    with ThreadPoolExecutor(max_workers=12) as pool:
        outcomes = list(pool.map(attempt, range(12)))
    assert outcomes.count("wrong") == auth.MAX_FAILED_ATTEMPTS
    assert outcomes.count("locked") == 12 - auth.MAX_FAILED_ATTEMPTS


def test_success_resets_budget_and_expired_locks_recover(server):
    for _ in range(auth.MAX_FAILED_ATTEMPTS - 1):
        assert _login(server, "dana", "wrong").status_code == 401
    assert _login(server, "dana", "correct horse battery staple").status_code == 200
    assert fetch_one_sync("SELECT COUNT(*) AS n FROM login_attempts")["n"] == 0
    for _ in range(auth.MAX_FAILED_ATTEMPTS):
        assert _login(server, "dana", "wrong").status_code == 401
    execute_write_sync("UPDATE login_attempts SET expires_at=?", (time.time() - 1,))
    assert _login(server, "dana", "correct horse battery staple").status_code == 200


def test_older_success_cannot_clear_a_newer_lockout(server, monkeypatch):
    started, release = threading.Event(), threading.Event()
    verify = auth.verify_password
    def delayed_verify(password, stored):
        if password == "correct horse battery staple":
            started.set()
            assert release.wait(5)
        return verify(password, stored)
    monkeypatch.setattr(auth, "verify_password", delayed_verify)
    with ThreadPoolExecutor(max_workers=1) as pool:
        old_login = pool.submit(auth.authenticate_sync, "dana", "correct horse battery staple")
        try:
            assert started.wait(5)
            for _ in range(auth.MAX_FAILED_ATTEMPTS - 1):
                with pytest.raises(auth.AuthError):
                    auth.authenticate_sync("dana", "wrong")
        finally:
            release.set()
        with pytest.raises(auth.AuthError) as rejected:
            old_login.result(timeout=5)
        assert rejected.value.locked
    assert _login(server, "dana", "correct horse battery staple").status_code == 429


# ---------------------------------------------------------------- tokens
def _bearer(token):
    return {"Authorization": f"Bearer {token}"}


def test_an_expired_token_is_refused(server, monkeypatch):
    token = auth.issue_token("dana", "clinician_reader", "default_patient", ttl_seconds=-1)
    assert server.get("/api/v1/report/neurologist", headers=_bearer(token)).status_code == 401


def test_a_token_signed_with_another_secret_is_refused(server):
    forged = jwt.encode(
        {"sub": "x", "role": "device_writer", "pid": "default_patient", "exp": int(time.time()) + 60},
        "a different secret " * 3,
        algorithm="HS256",
    )
    assert server.get("/api/v1/report/neurologist", headers=_bearer(forged)).status_code == 401


def test_an_unsigned_token_is_refused(server):
    unsigned = jwt.encode(
        {"sub": "x", "role": "device_writer", "pid": "default_patient", "exp": int(time.time()) + 60},
        key=None,
        algorithm="none",
    )
    assert server.get("/api/v1/report/neurologist", headers=_bearer(unsigned)).status_code == 401


def test_a_token_with_an_unknown_role_is_refused(server):
    token = auth.issue_token("x", "admin", "default_patient")
    assert server.get("/api/v1/report/neurologist", headers=_bearer(token)).status_code == 401


def test_shared_static_tokens_stop_working_when_disabled(server, monkeypatch):
    monkeypatch.setattr(settings, "allow_static_tokens", False)
    res = server.get("/api/v1/report/neurologist", headers=_bearer(settings.cadence_device_token))
    assert res.status_code == 401


# ---------------------------------------------------------------- startup
def test_production_refuses_to_start_without_a_strong_secret(monkeypatch):
    monkeypatch.setattr(settings, "cadence_env", "production")
    monkeypatch.setattr(settings, "jwt_secret", "")
    with pytest.raises(RuntimeError):
        auth.validate_security_settings()
    monkeypatch.setattr(settings, "jwt_secret", "short")
    with pytest.raises(RuntimeError):
        auth.validate_security_settings()
    monkeypatch.setattr(settings, "jwt_secret", "s" * 48)
    _configure_caregiver_dispatch(monkeypatch)
    auth.validate_security_settings()


def _configure_caregiver_dispatch(monkeypatch):
    monkeypatch.setattr(settings, "twilio_account_sid", "AC" + "0" * 32)
    monkeypatch.setattr(settings, "twilio_auth_token", "t" * 32)
    monkeypatch.setattr(settings, "twilio_from_phone", "+15550000000")
    monkeypatch.setattr(settings, "caregiver_primary_phone", "+15550000001")
    monkeypatch.setattr(settings, "public_webhook_base_url", "https://cadence.example.org")
    monkeypatch.setattr(settings, "demo_mode", None)
    monkeypatch.setattr(settings, "allow_static_tokens", None)


def test_production_refuses_to_start_with_no_way_to_reach_a_caregiver(monkeypatch):
    """A fall alert that can never be delivered must fail at startup, not at 3 a.m."""
    monkeypatch.setattr(settings, "cadence_env", "production")
    monkeypatch.setattr(settings, "jwt_secret", "s" * 48)
    _configure_caregiver_dispatch(monkeypatch)
    auth.validate_security_settings()

    for field in ("twilio_account_sid", "twilio_auth_token", "twilio_from_phone", "caregiver_primary_phone"):
        monkeypatch.setattr(settings, field, "")
        with pytest.raises(RuntimeError, match=field.upper()):
            auth.validate_security_settings()
        _configure_caregiver_dispatch(monkeypatch)

    monkeypatch.setattr(settings, "public_webhook_base_url", "http://cadence.example.org")
    with pytest.raises(RuntimeError, match="https"):
        auth.validate_security_settings()
    _configure_caregiver_dispatch(monkeypatch)

    monkeypatch.setattr(settings, "demo_mode", True)
    with pytest.raises(RuntimeError, match="DEMO_MODE"):
        auth.validate_security_settings()
    _configure_caregiver_dispatch(monkeypatch)

    monkeypatch.setattr(settings, "allow_static_tokens", True)
    with pytest.raises(RuntimeError, match="STATIC_TOKENS"):
        auth.validate_security_settings()


def test_production_defaults_turn_off_demo_and_static_tokens(monkeypatch):
    monkeypatch.setattr(settings, "cadence_env", "production")
    monkeypatch.setattr(settings, "demo_mode", None)
    monkeypatch.setattr(settings, "allow_static_tokens", None)
    assert settings.demo_mode_enabled is False
    assert settings.static_tokens_enabled is False


# ---------------------------------------------------------------- demo-only paths
def test_a_clinician_cannot_seed_demo_data(server):
    token = _login(server, "dana", "correct horse battery staple").json()["access_token"]
    assert server.post("/api/v1/demo/seed", headers=_bearer(token)).status_code == 403


def test_seeding_is_refused_when_demo_mode_is_off(server, monkeypatch):
    monkeypatch.setattr(settings, "demo_mode", False)
    token = _login(server, "phone-1", "device pass phrase long enough").json()["access_token"]
    res = server.post("/api/v1/demo/seed", headers=_bearer(token))
    assert res.status_code == 403
    assert "demo" in res.json()["message"].lower()


@pytest.mark.parametrize(
    "path,body",
    [
        ("/api/v1/reality-check", {"event_uuid": "rc-sim-1", "user_query": "anyone?", "simulated_sam_masks": []}),
        ("/api/v1/medication/meal-protein", {"event_uuid": "meal-sim-1", "simulated_masks": []}),
        ("/api/v1/handwriting/analyze", {"event_uuid": "hw-sim-1", "simulated_letter_heights_px": [40, 40, 30, 20]}),
    ],
)
def test_simulated_inputs_are_refused_outside_demo_mode(server, monkeypatch, path, body):
    monkeypatch.setattr(settings, "demo_mode", False)
    token = _login(server, "phone-1", "device pass phrase long enough").json()["access_token"]
    res = server.post(path, headers=_bearer(token), json=body)
    assert res.status_code == 400
    assert "demo" in res.json()["message"].lower()


def test_the_dashboard_no_longer_ships_a_token(server):
    html = server.get("/dashboard").text
    script = server.get('/assets/dashboard.js').text
    for content in (html, script):
        assert settings.cadence_device_token not in content
        assert settings.cadence_clinician_token not in content
    assert "/api/v1/auth/login" in script
