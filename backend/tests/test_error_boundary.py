"""Errors reach the phone as one plain sentence; the details stay in the server log."""

import logging

import pytest
from fastapi import APIRouter
from fastapi.testclient import TestClient

from app.config import settings
from app.db import init_db_sync
from app.main import app

DEVICE_HEADERS = {"Authorization": f"Bearer {settings.cadence_device_token}"}


@pytest.fixture
def client(monkeypatch, tmp_path):
    monkeypatch.setattr(settings, "sqlite_db_path", str(tmp_path / "errors.db"))
    init_db_sync()
    router = APIRouter()

    @router.get("/__test/boom")
    async def boom():
        raise RuntimeError("database file /secret/path is corrupt; token=abc123")

    app.include_router(router)
    try:
        with TestClient(app, raise_server_exceptions=False) as http:
            yield http
    finally:
        app.router.routes[:] = [r for r in app.router.routes if getattr(r, "path", "") != "/__test/boom"]


def test_an_unhandled_exception_is_logged_and_hidden(client, caplog):
    with caplog.at_level(logging.ERROR, logger="cadence"):
        response = client.get("/__test/boom")

    assert response.status_code == 500
    body = response.json()
    assert body == {
        "error": "server_error",
        "message": "Something went wrong on our side. Your data is saved on the phone and will be sent again.",
    }
    assert "corrupt" not in response.text
    assert "abc123" not in response.text
    assert "Traceback" not in response.text
    assert any("corrupt" in record.getMessage() or record.exc_info for record in caplog.records), \
        "the real cause must be in the server log"


def test_validation_errors_name_the_field_in_plain_words(client):
    response = client.post(
        "/api/v1/events/fog",
        headers=DEVICE_HEADERS,
        json={"event_uuid": "x", "duration_sec": -1, "peak_freeze_index": 3.0,
              "locomotor_band_power": 0.05, "freeze_band_power": 0.2},
    )
    assert response.status_code == 422
    body = response.json()
    assert body["error"] == "invalid_request"
    assert "problems" in body
    fields = {p["field"] for p in body["problems"]}
    assert "event_uuid" in fields
    assert "duration_sec" in fields
    for problem in body["problems"]:
        assert "ctx" not in problem
        assert isinstance(problem["message"], str) and problem["message"]


def test_auth_failures_keep_their_status_and_shape(client):
    response = client.post("/api/v1/events/fog", json={})
    assert response.status_code == 401
    body = response.json()
    assert body["error"] == "unauthorized"
    assert "message" in body
