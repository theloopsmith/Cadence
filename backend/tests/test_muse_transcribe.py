"""Muse Voice Transcribe: the phone sends a short clip, the backend asks Meta, the clip is never kept."""

import asyncio
import base64
import io
import json
import struct
import wave

import pytest
from fastapi.testclient import TestClient

from app.clients.circuit_breaker import circuit_breakers
from app.clients.meta_models import MetaModelClient, check_in_keywords
from app.config import settings
from app.db import init_db_sync
from app.main import app

DEVICE = {"Authorization": f"Bearer {settings.cadence_device_token}"}


def _wav(seconds: float = 1.0, rate: int = 16000) -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(struct.pack("<h", 0) * int(seconds * rate))
    return buf.getvalue()


class _Resp:
    def __init__(self, status=200, text=""):
        self.status_code = status
        self.text = text

    def raise_for_status(self):
        if self.status_code >= 400:
            raise RuntimeError(f"HTTP {self.status_code}")


class _Capture:
    calls = []
    reply = _Resp(200, "Help me\n")

    def __init__(self, timeout):
        self.timeout = timeout

    async def __aenter__(self):
        return self

    async def __aexit__(self, *exc):
        return None

    async def post(self, url, headers, files):
        _Capture.calls.append({"url": url, "headers": headers, "files": files})
        return _Capture.reply


@pytest.fixture
def capture(monkeypatch):
    _Capture.calls = []
    _Capture.reply = _Resp(200, "Help me\n")
    monkeypatch.setattr(settings, "meta_api_key", "test-key")
    monkeypatch.setattr("app.clients.meta_models.httpx.AsyncClient", _Capture)
    circuit_breakers.reset_all()
    return _Capture


def test_the_request_matches_the_documented_api(capture):
    result = asyncio.run(
        MetaModelClient().transcribe_muse_voice(_wav(), keywords=["I'm okay", "help"])
    )
    assert result == {"available": True, "transcript": "Help me"}
    call = capture.calls[0]
    assert call["url"] == "https://api.meta.ai/v1/asr/transcribe"
    assert call["headers"]["Authorization"] == "Bearer test-key"
    assert call["headers"]["Accept"] == "text/plain"
    request = json.loads(call["files"]["request"][1])
    assert request["model"] == "muse-voice-transcribe-1.0"
    assert request["audioEncoding"] == "WAV"
    assert request["mode"] == "PUSH_TO_TALK"
    assert request["keywords"] == ["I'm okay", "help"]
    assert request["languageBias"] == ["english"]
    assert call["files"]["audio"][2] == "audio/wav"


def test_multiple_lines_are_joined(capture):
    capture.reply = _Resp(200, "I'm\nokay\n")
    result = asyncio.run(MetaModelClient().transcribe_muse_voice(_wav(), keywords=[]))
    assert result["transcript"] == "I'm okay"


def test_without_a_key_it_reports_unavailable(monkeypatch):
    monkeypatch.setattr(settings, "meta_api_key", "")
    result = asyncio.run(MetaModelClient().transcribe_muse_voice(_wav(), keywords=[]))
    assert result["available"] is False


def test_failures_trip_the_breaker_and_stop_calling(capture):
    capture.reply = _Resp(500, "")
    client = MetaModelClient()
    for _ in range(3):
        assert asyncio.run(client.transcribe_muse_voice(_wav(), keywords=[]))["available"] is False
    calls_before = len(capture.calls)
    assert asyncio.run(client.transcribe_muse_voice(_wav(), keywords=[]))["reason"] == "circuit_open"
    assert len(capture.calls) == calls_before


def test_check_in_keywords_include_both_answers():
    words = check_in_keywords()
    assert "I'm okay" in words and "help" in words


# ---------------------------------------------------------------- endpoint
@pytest.fixture
def client(monkeypatch, tmp_path, capture):
    monkeypatch.setattr(settings, "sqlite_db_path", str(tmp_path / "asr.db"))
    init_db_sync()
    with TestClient(app) as http:
        yield http


def test_the_endpoint_transcribes_with_purpose_keywords(client, capture):
    res = client.post(
        "/api/v1/speech/transcribe",
        headers=DEVICE,
        json={
            "audio_base64": base64.b64encode(_wav()).decode(),
            "purpose": "dose",
            "keywords": ["Sinemet"],
        },
    )
    assert res.status_code == 200
    assert res.json() == {"available": True, "transcript": "Help me", "source": "muse_voice_transcribe"}
    sent = json.loads(capture.calls[0]["files"]["request"][1])["keywords"]
    assert "taken" in sent and "Sinemet" in sent


def test_the_endpoint_refuses_anything_but_a_wav(client):
    res = client.post(
        "/api/v1/speech/transcribe",
        headers=DEVICE,
        json={"audio_base64": base64.b64encode(b"not audio at all").decode(), "purpose": "fall_check_in"},
    )
    assert res.status_code == 400


def test_the_endpoint_refuses_long_clips(client):
    res = client.post(
        "/api/v1/speech/transcribe",
        headers=DEVICE,
        json={"audio_base64": base64.b64encode(_wav(seconds=40)).decode(), "purpose": "fall_check_in"},
    )
    assert res.status_code == 413


def test_the_endpoint_needs_the_device_role(client):
    res = client.post(
        "/api/v1/speech/transcribe",
        headers={"Authorization": f"Bearer {settings.cadence_clinician_token}"},
        json={"audio_base64": base64.b64encode(_wav()).decode(), "purpose": "fall_check_in"},
    )
    assert res.status_code == 403


def test_no_text_to_speech_call_exists():
    """Meta offers no voice-output API; the old call to a nonexistent endpoint is gone."""
    assert not hasattr(MetaModelClient(), "synthesize_muse_voice")
