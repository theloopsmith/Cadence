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
from app.db import execute_write, fetch_all, fetch_one, init_db_sync  # noqa: E402
from app.models import FallEventCreate  # noqa: E402
from app.services.fall_escalation import FallEscalationManager  # noqa: E402

init_db_sync()


@pytest.fixture(autouse=True)
def isolated_dispatch_database(monkeypatch, tmp_path):
    # The durable recovery sweep intentionally scans all jobs, so each scenario
    # needs its own database rather than inheriting jobs from earlier scenarios.
    monkeypatch.setattr(settings, "sqlite_db_path", str(tmp_path / "scenario.db"))
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
        # The loop must stop promptly; a bounded wait avoids a one-tick race under load.
        try:
            await asyncio.wait_for(asyncio.shield(task), timeout=2.0)
        except (asyncio.TimeoutError, asyncio.CancelledError):
            pass
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


# --------------------------------------------------------------------------
# A cancel that reaches the backend before the fall must still win
# --------------------------------------------------------------------------
def test_cancel_that_arrives_before_the_fall_blocks_the_later_dispatch(dispatches):
    """
    Offline, the cancel request can drain before the fall it refers to. The
    cancel used to update zero rows, and the fall that arrived afterward
    called the caregiver anyway.
    """

    async def scenario():
        mgr = FallEscalationManager()
        cleared = await mgr.cancel_dispatched_fall("default_patient", "early-cancel-001")
        res = await mgr.ingest_fall_event("default_patient", _fall("early-cancel-001"))
        row = await fetch_one(
            "SELECT status FROM fall_events WHERE event_uuid = ?", ("early-cancel-001",)
        )
        return cleared, res, row

    cleared, res, row = asyncio.run(scenario())
    assert cleared["all_clear_sms_sent"] == 0
    assert res["twilio_dispatched"] is False
    assert row["status"] == "canceled_false_alarm"
    assert dispatches == []


# --------------------------------------------------------------------------
# SMS and the voice call are independent, and a total failure stays retryable
# --------------------------------------------------------------------------
def test_an_sms_failure_still_places_the_voice_call(monkeypatch):
    """One Twilio exception used to abort both channels, so a dead SMS path
    meant nobody was called."""
    import sys
    import types

    monkeypatch.setattr(settings, "twilio_account_sid", "ACtest")
    monkeypatch.setattr(settings, "twilio_auth_token", "token")
    monkeypatch.setattr(settings, "twilio_from_phone", "+15551110000")

    placed = []

    class _Messages:
        def create(self, **kwargs):
            raise RuntimeError("sms down")

    class _Calls:
        def create(self, **kwargs):
            placed.append(kwargs)
            return types.SimpleNamespace(sid="CA_OK")

    class _Client:
        def __init__(self, sid, token, **kwargs):
            self.messages = _Messages()
            self.calls = _Calls()

    try:
        import twilio.rest as rest

        monkeypatch.setattr(rest, "Client", _Client)
    except ImportError:
        rest_mod = types.ModuleType("twilio.rest")
        rest_mod.Client = _Client
        monkeypatch.setitem(sys.modules, "twilio", types.ModuleType("twilio"))
        monkeypatch.setitem(sys.modules, "twilio.rest", rest_mod)

    res = asyncio.run(
        twilio_client.dispatch_sms_and_call(
            to_phone="+15550001111",
            event_uuid="sms-fail-001",
            peak_impact_g=3.8,
            timestamp_utc="2026-10-27T19:00:00Z",
        )
    )
    assert placed, "the voice call must be placed even when the SMS raises"
    assert res["call_sid"] == "CA_OK"
    assert res["sms_sid"] == ""
    assert res["delivery_status"] == "partial"


def test_total_dispatch_failure_leaves_the_fall_retryable(monkeypatch, slow_retry):
    """A fall whose SMS and call both fail was stored as escalated, so the
    device queue treated it as delivered and never tried again."""

    async def boom(**kwargs):
        return {
            "sms_sid": "",
            "call_sid": "",
            "sms_body": "x",
            "twiml": "",
            "delivery_status": "failed:sms down",
        }

    monkeypatch.setattr(twilio_client, "dispatch_sms_and_call", boom)

    async def scenario():
        mgr = FallEscalationManager()
        res = await mgr.ingest_fall_event("default_patient", _fall("fail-001"))
        row = await fetch_one(
            "SELECT status FROM fall_events WHERE event_uuid = ?", ("fail-001",)
        )
        return mgr, res, row, await _alerts("fail-001")

    mgr, res, row, alerts = asyncio.run(scenario())
    assert res["twilio_dispatched"] is False
    assert row["status"] == "confirmed_waiting_dispatch"
    assert "fail-001" not in mgr._active_tasks
    assert alerts == []


# --------------------------------------------------------------------------
# A terminal call status escalates once, and a restart keeps the window
# --------------------------------------------------------------------------
def test_a_second_terminal_status_does_not_redial_the_secondary(
    dispatches, slow_retry, monkeypatch
):
    """Every status callback used retry_count=1, so the secondary's own
    no-answer placed another call to the secondary."""
    monkeypatch.setattr(settings, "caregiver_secondary_phone", "+15550002222")

    async def scenario():
        mgr = FallEscalationManager()
        await mgr.ingest_fall_event("default_patient", _fall("status-001"))
        first = await mgr.handle_status_webhook("status-001", "no-answer")
        second = await mgr.handle_status_webhook("status-001", "no-answer")
        mgr._active_tasks["status-001"].cancel()
        return first, second, await _alerts("status-001")

    first, second, alerts = asyncio.run(scenario())
    assert first["escalated"] is True
    assert second["escalated"] is False
    voice = [a for a in alerts if a["channel"] == "voice_call"]
    assert [a["contact_role"] for a in voice] == ["primary", "secondary"]
    assert len(dispatches) == 2


def test_the_status_webhook_and_the_retry_loop_dial_the_secondary_once(
    dispatches, monkeypatch
):
    monkeypatch.setattr(settings, "caregiver_secondary_phone", "+15550002222")

    async def scenario():
        mgr = FallEscalationManager()
        await mgr.ingest_fall_event(
            "default_patient", _fall("once-001"), start_background_retry=False
        )
        results = await asyncio.gather(
            mgr.escalate_to_secondary_or_retry_primary(
                "default_patient", "once-001", retry_count=1
            ),
            mgr.escalate_to_secondary_or_retry_primary(
                "default_patient", "once-001", retry_count=1
            ),
        )
        return results, await _alerts("once-001")

    results, alerts = asyncio.run(scenario())
    assert sorted(r["dispatched"] for r in results) == [False, True]
    voice = [a for a in alerts if a["channel"] == "voice_call"]
    assert [a["contact_role"] for a in voice] == ["primary", "secondary"]
    assert len(dispatches) == 2


def test_a_restarted_manager_resumes_an_unacknowledged_escalation(
    dispatches, monkeypatch
):
    """The retry loop lived only in process memory. A restart stopped calling
    while the phone siren was still telling the wearer help was on the way."""
    monkeypatch.setattr(settings, "secondary_escalation_delay_sec", 0.01)
    monkeypatch.setattr(settings, "retry_interval_sec", 0.01)
    monkeypatch.setattr(settings, "max_retry_attempts", 2)
    monkeypatch.setattr(settings, "retry_window_sec", 5.0)
    monkeypatch.setattr(settings, "caregiver_secondary_phone", "+15550002222")

    async def scenario():
        down = FallEscalationManager()
        await down.ingest_fall_event(
            "default_patient", _fall("resume-001"), start_background_retry=False
        )
        restarted = FallEscalationManager()
        resumed = await restarted.resume_open_escalations()
        await asyncio.wait_for(restarted._active_tasks["resume-001"], timeout=5.0)
        return resumed, await _alerts("resume-001")

    resumed, alerts = asyncio.run(scenario())
    assert "resume-001" in resumed
    voice = [a for a in alerts if a["channel"] == "voice_call" and a["contact_role"] == "secondary"]
    assert voice, alerts
    assert len(dispatches) >= 2


def test_resume_does_not_revive_a_window_that_already_elapsed(dispatches, monkeypatch):
    monkeypatch.setattr(settings, "retry_window_sec", 900.0)
    monkeypatch.setattr(settings, "caregiver_secondary_phone", "+15550002222")

    async def scenario():
        down = FallEscalationManager()
        await down.ingest_fall_event(
            "default_patient", _fall("stale-001"), start_background_retry=False
        )
        await execute_write(
            "UPDATE caregiver_alerts SET timestamp_utc = ? WHERE fall_event_uuid = ?",
            ("2020-01-01T00:00:00+00:00", "stale-001"),
        )
        # The persisted job deadline, not an editable audit timestamp, owns the retry window.
        await execute_write("UPDATE fall_jobs SET deadline=0 WHERE event_uuid=?", ("stale-001",))
        restarted = FallEscalationManager()
        await restarted.resume_open_escalations()
        task = restarted._active_tasks.get("stale-001")
        if task is not None:
            await asyncio.wait_for(task, timeout=5.0)
        return await _alerts("stale-001")

    alerts = asyncio.run(scenario())
    assert len(dispatches) == 1, "an elapsed window must not place another call"
    assert alerts
    assert all(a["delivery_status"] == "exhausted_15m" for a in alerts)
