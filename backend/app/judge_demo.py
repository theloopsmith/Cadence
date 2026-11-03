"""Public model previews with fixed inputs and a durable admission budget."""

import asyncio
import math
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Literal

from fastapi import HTTPException, Request

from app.clients.baseten_llm import baseten_client
from app.clients.circuit_breaker import RequestDeadlineContext
from app.clients.meta_models import meta_client
from app.config import settings
from app.db import execute_write
from app.rate_limit import InferenceQuota
from app.services.companion import interpret
from app.services.handwriting import PHOTO_QUALITY_ADVICE
from app.services.reality_check import run_reality_check_pipeline

samples = Path(__file__).parent / "static" / "walkthrough"
client_quota = InferenceQuota()
active_runs = 0


async def reserve_daily_run(now: datetime) -> None:
    # One row and one atomic conditional write. Admission is charged before
    # inference, even if the client disconnects or the provider fails.
    day = now.date()
    changed = await execute_write(
        """
        INSERT INTO judge_demo_quota (id, utc_day, admitted_runs)
        VALUES (1, ?, 1)
        ON CONFLICT(id) DO UPDATE SET
            utc_day = excluded.utc_day,
            admitted_runs = CASE
                WHEN judge_demo_quota.utc_day < excluded.utc_day THEN 1
                ELSE judge_demo_quota.admitted_runs + 1
            END
        WHERE judge_demo_quota.utc_day < excluded.utc_day
           OR (judge_demo_quota.utc_day = excluded.utc_day AND judge_demo_quota.admitted_runs < ?)
        """,
        (day.isoformat(), settings.judge_demo_daily_runs),
    )
    if not changed:
        midnight = datetime.combine(day + timedelta(days=1), datetime.min.time(), timezone.utc)
        retry = max(1, math.ceil((midnight - now).total_seconds()))
        raise HTTPException(429, "Today's live demo quota is used up. Try again after midnight UTC.",
                            headers={"Retry-After": str(retry)})


async def judge_demo(action: Literal["intent", "surroundings", "handwriting", "voice"], request: Request):
    global active_runs
    now = datetime.now(timezone.utc)
    if not settings.demo_mode_enabled or (
        settings.cadence_env.strip().lower() == "public_demo" and now >= settings.demo_accounts_expire_at_utc
    ):
        raise HTTPException(404, "The live judge demo is closed.")

    # This endpoint takes only the action in the path. Reject bodies before
    # reading them, including streamed requests with no Content-Length.
    if request.url.query or request.headers.get("transfer-encoding") or request.headers.get("content-length", "0") != "0":
        raise HTTPException(400, "Choose a demo action without supplying input.")

    # Uvicorn accepts forwarding headers only from the loopback Caddy proxy.
    client = request.client.host if request.client else "unknown"
    client_quota.consume(client, settings.judge_demo_runs_per_ip_minute)
    # The deployed VM uses one Uvicorn worker. There is no await between
    # checking and taking a slot on its event loop.
    if active_runs >= settings.judge_demo_max_concurrent:
        raise HTTPException(429, "The live demo is busy. Try again in a few seconds.",
                            headers={"Retry-After": "5"})
    active_runs += 1
    try:
        await reserve_daily_run(now)
        async with asyncio.timeout(28):
            if action == "intent":
                return await interpret("Did I log my morning medication today?", [])
            if action == "surroundings":
                result = await run_reality_check_pipeline(
                    user_query="What objects can you identify in this illustrated photo?",
                    image_bytes=(samples / "coatstand.jpg").read_bytes(),
                    deadline=RequestDeadlineContext(),
                )
                return {key: result[key] for key in ("analysis_status", "model_evidence", "spoken_response")}
            if action == "handwriting":
                review = await baseten_client.check_handwriting_photo(
                    (samples / "handwriting-capture.jpg").read_bytes(),
                    RequestDeadlineContext(total_budget_sec=25),
                )
                if review is None:
                    return {"photo_quality": {"status": "unavailable"}}
                quality = next(iter(review["labels"]), "uncertain")
                return {"photo_quality": {"status": quality, "advice": PHOTO_QUALITY_ADVICE.get(quality),
                                          "model": review["model"], "provider": review["provider"]}}
            voice = await meta_client.transcribe_muse_voice(
                (samples / "judge-voice.wav").read_bytes(), keywords=["Cadence", "motor check"],
            )
            return {"available": voice["available"], "transcript": voice["transcript"]}
    except TimeoutError:
        raise HTTPException(504, "The model timed out. Try again shortly.") from None
    finally:
        active_runs -= 1
