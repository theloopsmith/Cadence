import asyncio
from datetime import datetime, timedelta, timezone
from unittest.mock import AsyncMock

import pytest
from fastapi import HTTPException
from fastapi.testclient import TestClient

from app import judge_demo
from app.config import settings
from app.db import init_db_sync
from app.main import app
from app.rate_limit import InferenceQuota


@pytest.fixture
def demo(monkeypatch, tmp_path):
    monkeypatch.setattr(settings, "sqlite_db_path", str(tmp_path / "demo.sqlite"))
    monkeypatch.setattr(settings, "demo_mode", True)
    monkeypatch.setattr(settings, "judge_demo_daily_runs", 2)
    monkeypatch.setattr(judge_demo, "client_quota", InferenceQuota())
    init_db_sync()


def test_action_rejects_caller_inputs_and_shares_durable_quota(demo, monkeypatch):
    model = AsyncMock(return_value={"intent": "unknown"})
    monkeypatch.setattr(judge_demo, "interpret", model)
    voice = AsyncMock(return_value={"available": True, "transcript": "Sample"})
    monkeypatch.setattr(judge_demo.meta_client, "transcribe_muse_voice", voice)
    client = TestClient(app)
    base = "/api/v1/judge-demo/"
    assert client.post(base + "intent", json={"text": "custom text"}).status_code == 400
    assert client.post(base + "voice?purpose=fall_check_in").status_code == 400
    assert client.post(base + "unknown").status_code == 422
    assert client.post(base + "intent").status_code == 200
    model.assert_awaited_once_with("Did I log my morning medication today?", [])
    assert client.post(base + "voice").status_code == 200
    # Replace process-local rate state as a restart would, while keeping SQLite.
    monkeypatch.setattr(judge_demo, "client_quota", InferenceQuota())
    limited = TestClient(app).post(base + "voice")
    assert limited.status_code == 429
    assert int(limited.headers["retry-after"]) > 0
    voice.assert_awaited_once()


def test_atomic_admission_and_utc_rollover(demo):
    async def exercise():
        now = datetime.now(timezone.utc)
        results = await asyncio.gather(
            *(judge_demo.reserve_daily_run(now) for _ in range(8)),
            return_exceptions=True,
        )
        assert results.count(None) == 2
        assert all(isinstance(result, HTTPException) and result.status_code == 429
                   for result in results if result is not None)
        await judge_demo.reserve_daily_run(now + timedelta(days=1))

    asyncio.run(exercise())


def test_ip_and_concurrency_limits_prevent_provider_work(demo, monkeypatch):
    import httpx

    monkeypatch.setattr(settings, "judge_demo_runs_per_ip_minute", 1)
    monkeypatch.setattr(settings, "judge_demo_max_concurrent", 1)

    async def exercise():
        started = asyncio.Event()
        release = asyncio.Event()

        async def model(*args):
            started.set()
            await release.wait()
            return {"intent": "unknown"}

        call_model = AsyncMock(side_effect=model)
        monkeypatch.setattr(judge_demo, "interpret", call_model)
        path = "/api/v1/judge-demo/intent"
        first = httpx.ASGITransport(app=app, client=("192.0.2.1", 1234))
        second = httpx.ASGITransport(app=app, client=("192.0.2.2", 1234))
        async with (
            httpx.AsyncClient(transport=first, base_url="http://test") as client,
            httpx.AsyncClient(transport=second, base_url="http://test") as other,
        ):
            pending = asyncio.create_task(client.post(path))
            try:
                await asyncio.wait_for(started.wait(), timeout=2)
                # A supplied forwarding header cannot change the ASGI client key.
                limited = await client.post(path, headers={"X-Forwarded-For": "192.0.2.3"})
                assert limited.status_code == 429
                assert limited.headers["retry-after"] != "5"
                busy = await other.post(path)
                assert busy.status_code == 429
                assert busy.headers["retry-after"] == "5"
            finally:
                release.set()
                assert (await pending).status_code == 200
        call_model.assert_awaited_once()

    asyncio.run(exercise())
