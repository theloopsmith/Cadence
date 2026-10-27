"""
Regression tests for fall-path defects found in the Day 2 code review (Oct 27).

Each was reproduced against the running backend before the fix:
  - the Stage 3 candidate row dispatched Twilio before the check-in began
  - a repeated fall POST dispatched the caregiver twice and orphaned a retry loop
  - a cancel posted to /events/fall after dispatch left the retry loop running
"""

import asyncio
import os
import tempfile

import pytest

_tmp_db = tempfile.NamedTemporaryFile(suffix=".db", delete=False)
_tmp_db.close()
os.environ.setdefault("SQLITE_DB_PATH", _tmp_db.name)

from app.clients.twilio_client import twilio_client  # noqa: E402
from app.config import settings  # noqa: E402
from app.db import fetch_all, fetch_one, init_db_sync  # noqa: E402
from app.models import FallEventCreate  # noqa: E402
from app.services.fall_escalation import FallEscalationManager  # noqa: E402

init_db_sync()


@pytest.fixture
def dispatches(monkeypatch):
    """Records every caregiver dispatch while still running the simulated client."""
    calls = []
    original = twilio_client.dispatch_sms_and_call

    async def spy(**kwargs):
        calls.append(kwargs)
        return await original(**kwargs)

    monkeypatch.setattr(twilio_client, "dispatch_sms_and_call", spy)
    return calls


@pytest.fixture
def slow_retry(monkeypatch):
    """Keeps the retry loop parked in its first sleep for the life of a test."""
    monkeypatch.setattr(settings, "secondary_escalation_delay_sec", 30.0)


def _fall(uuid: str, status: str = "confirmed_waiting_dispatch", **overrides) -> FallEventCreate:
    fields = dict(
        event_uuid=uuid,
        peak_impact_g=3.8,
        peak_jerk_gs=44.0,
        post_impact_tilt_deg=71.0,
        status=status,
    )
    fields.update(overrides)
    return FallEventCreate(**fields)


async def _alerts(uuid: str):
    return await fetch_all(
        "SELECT contact_role, channel, delivery_status FROM caregiver_alerts "
        "WHERE fall_event_uuid = ? ORDER BY id",
        (uuid,),
    )


# --------------------------------------------------------------------------
# The Stage 3 candidate is a local safety record, not a dispatch request
# --------------------------------------------------------------------------
def test_stage3_candidate_is_recorded_without_contacting_anyone(dispatches):
    """
    FallDetector queues a 'candidate_check_in_pending' row the moment Stage 3
    completes, before the wearer has had 12 seconds to say "I'm okay". Treating
    it as confirmed called the caregiver on every detected impact.
    """

    async def scenario():
        mgr = FallEscalationManager()
        res = await mgr.ingest_fall_event(
            "default_patient", _fall("cand-001", "candidate_check_in_pending")
        )
        row = await fetch_one(
            "SELECT status FROM fall_events WHERE event_uuid = ?", ("cand-001",)
        )
        return mgr, res, row, await _alerts("cand-001")

    mgr, res, row, alerts = asyncio.run(scenario())
    assert res["twilio_dispatched"] is False
    assert row["status"] == "candidate_check_in_pending"
    assert dispatches == []
    assert alerts == []
    assert "cand-001" not in mgr._active_tasks


def test_confirmation_after_a_candidate_dispatches_with_the_recorded_impact(dispatches, slow_retry):
    """
    The escalation the coordinator posts after the check-in carries no impact
    figures of its own. The caregiver SMS must use the values recorded at
    Stage 3, not report a 0.0 g impact.
    """

    async def scenario():
        mgr = FallEscalationManager()
        await mgr.ingest_fall_event(
            "default_patient", _fall("cand-002", "candidate_check_in_pending")
        )
        res = await mgr.ingest_fall_event(
            "default_patient",
            _fall("cand-002", peak_impact_g=0.0, peak_jerk_gs=0.0, post_impact_tilt_deg=0.0),
        )
        mgr._active_tasks["cand-002"].cancel()
        return res

    res = asyncio.run(scenario())
    assert res["twilio_dispatched"] is True
    assert len(dispatches) == 1
    assert dispatches[0]["peak_impact_g"] == pytest.approx(3.8)
    assert "3.8g" in res["sms_body"]


def test_cancel_inside_the_check_in_window_never_dispatches(dispatches):
    async def scenario():
        mgr = FallEscalationManager()
        await mgr.ingest_fall_event(
            "default_patient", _fall("cand-003", "candidate_check_in_pending")
        )
        res = await mgr.ingest_fall_event(
            "default_patient",
            _fall("cand-003", "canceled_false_alarm", cancel_transcript="i'm okay"),
        )
        row = await fetch_one(
            "SELECT status FROM fall_events WHERE event_uuid = ?", ("cand-003",)
        )
        return res, row

    res, row = asyncio.run(scenario())
    assert res["twilio_dispatched"] is False
    assert row["status"] == "canceled_false_alarm"
    assert dispatches == []


# --------------------------------------------------------------------------
# A repeated fall POST must not call the caregiver twice
# --------------------------------------------------------------------------
def test_duplicate_fall_post_dispatches_the_caregiver_once(dispatches, slow_retry):
    """
    The iOS queue retries on timeouts and can drain from two paths at once.
    The row insert was idempotent but the dispatch was not: each repeat placed
    another SMS and call and started a second retry loop that could no longer
    be cancelled.
    """

    async def scenario():
        mgr = FallEscalationManager()
        first = await mgr.ingest_fall_event("default_patient", _fall("dup-001"))
        first_task = mgr._active_tasks["dup-001"]
        second = await mgr.ingest_fall_event("default_patient", _fall("dup-001"))
        same_task = mgr._active_tasks["dup-001"] is first_task
        first_task.cancel()
        row = await fetch_one(
            "SELECT status FROM fall_events WHERE event_uuid = ?", ("dup-001",)
        )
        return first, second, same_task, row, await _alerts("dup-001")

    first, second, same_task, row, alerts = asyncio.run(scenario())
    assert first["twilio_dispatched"] is True
    assert second["twilio_dispatched"] is False
    assert len(dispatches) == 1
    assert same_task, "a duplicate must not replace the live retry loop"
    assert row["status"] == "escalated_twilio", "a duplicate must not downgrade the status"
    assert [a["contact_role"] for a in alerts] == ["primary"]


def test_concurrent_duplicate_fall_posts_dispatch_once(dispatches, slow_retry):
    async def scenario():
        mgr = FallEscalationManager()
        results = await asyncio.gather(
            mgr.ingest_fall_event("default_patient", _fall("dup-002")),
            mgr.ingest_fall_event("default_patient", _fall("dup-002")),
        )
        for task in mgr._active_tasks.values():
            task.cancel()
        return results

    results = asyncio.run(scenario())
    assert sorted(r["twilio_dispatched"] for r in results) == [False, True]
    assert len(dispatches) == 1


# --------------------------------------------------------------------------
# A cancel that arrives on /events/fall after dispatch must stand everything down
# --------------------------------------------------------------------------
def test_cancel_posted_after_dispatch_halts_the_loop_and_sends_the_all_clear(dispatches, slow_retry):
    """
    Once caregivers have been contacted, a 'canceled_false_alarm' for the same
    event used to update the fall row only. The retry loop checks
    caregiver_alerts, so it kept calling for 15 minutes and nobody was told
    the alert was over.
    """

    async def scenario():
        mgr = FallEscalationManager()
        await mgr.ingest_fall_event("default_patient", _fall("late-cancel-001"))
        task = mgr._active_tasks["late-cancel-001"]
        await mgr.ingest_fall_event(
            "default_patient",
            _fall("late-cancel-001", "canceled_false_alarm", cancel_transcript="i'm fine"),
        )
        await asyncio.sleep(0)
        row = await fetch_one(
            "SELECT status FROM fall_events WHERE event_uuid = ?", ("late-cancel-001",)
        )
        return mgr, task, row, await _alerts("late-cancel-001")

    mgr, task, row, alerts = asyncio.run(scenario())
    assert task.done(), "the retry loop must stop, not sleep on toward the next call"
    assert "late-cancel-001" not in mgr._active_tasks
    assert row["status"] == "canceled_false_alarm"
    assert any(a["channel"] == "all_clear_sms" for a in alerts), alerts
    assert all(a["delivery_status"] == "canceled_by_user" for a in alerts)
    assert len(dispatches) == 1
