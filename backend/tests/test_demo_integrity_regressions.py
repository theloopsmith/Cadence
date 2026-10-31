"""
Regression tests for defects found in the first full code review (Oct 26).

Each test pins a behaviour that was silently wrong and that no existing test
covered. They are grouped by the defect they guard against so a future
regression names itself in the failure output.
"""

from datetime import datetime, timezone
import asyncio
import os
import tempfile

import pytest
from fastapi.testclient import TestClient

_tmp_db = tempfile.NamedTemporaryFile(suffix=".db", delete=False)
_tmp_db.close()
os.environ["SQLITE_DB_PATH"] = _tmp_db.name

from app.config import settings  # noqa: E402
from app.db import fetch_all, init_db_sync  # noqa: E402
from app.main import app  # noqa: E402
from app.models import FallEventCreate  # noqa: E402
from app.services.diary_engine import build_24h_diary_timeline  # noqa: E402
from app.services.fall_escalation import FallEscalationManager  # noqa: E402
from app.services.protein_checker import estimate_meal_protein, mask_area  # noqa: E402
from app.services.reality_check import (  # noqa: E402
    CLOSED_REALITY_VOCAB,
    run_reality_check_pipeline,
)

init_db_sync()

DEVICE_HEADERS = {"Authorization": f"Bearer {settings.cadence_device_token}"}


# --------------------------------------------------------------------------
# Defect 1: plate normalization silently skipped when masks report area_ratio
# --------------------------------------------------------------------------
def test_plate_normalization_accepts_both_area_units():
    """
    SAM 3.1 reports absolute pixel area; the dashboard and demo fixtures report
    fractional frame coverage. Both must normalize identically, because only the
    food-to-plate quotient is used. Previously an area_ratio frame fell through
    to the no-plate scale = 1.0 path and under-reported protein.
    """
    px = estimate_meal_protein(
        [
            {"label": "steak", "area_px": 34000.0, "confidence": 0.94},
            {"label": "plate", "area_px": 72000.0, "confidence": 0.98},
        ]
    )
    ratio = estimate_meal_protein(
        [
            {"label": "steak", "area_ratio": 0.34, "confidence": 0.94},
            {"label": "plate", "area_ratio": 0.72, "confidence": 0.98},
        ]
    )

    assert px["plate_detected"] is True
    assert ratio["plate_detected"] is True
    assert px["estimated_protein_grams"] == ratio["estimated_protein_grams"]
    # 0.34/0.72 = 0.472 coverage; 0.472/0.35 r_ref = 1.35 scale; 28g * 1.35
    assert px["estimated_protein_grams"] == pytest.approx(37.8, abs=0.05)
    assert px["items"][0]["scale"] == pytest.approx(1.35, abs=0.01)


def test_mask_area_falls_back_to_zero_without_an_area_key():
    assert mask_area({"label": "steak", "confidence": 0.9}) == 0.0
    assert mask_area({"area_px": None}) == 0.0


def test_no_plate_detected_still_falls_back_to_unit_scale():
    res = estimate_meal_protein(
        [{"label": "chicken", "area_px": 20000.0, "confidence": 0.9}]
    )
    assert res["plate_detected"] is False
    assert res["items"][0]["scale"] == 1.0
    assert res["estimated_protein_grams"] == pytest.approx(26.0, abs=0.05)


# --------------------------------------------------------------------------
# Defect 2: demo reality-check label fell outside the closed vocabulary
# --------------------------------------------------------------------------
def test_coat_rack_is_in_the_closed_vocabulary_and_reads_as_a_fixture():
    """
    A coat rack in dim light is a textbook Parkinson's hallucination trigger and
    is what the demo asks about. When it was missing from the vocabulary the
    pipeline degraded to the generic empty-space template, losing the grounded
    answer that is the whole point of Pipeline 4.
    """
    assert "coat rack" in CLOSED_REALITY_VOCAB

    res = asyncio.run(
        run_reality_check_pipeline(
            user_query="Is someone standing by the coat rack?",
            image_bytes=None,
            simulated_sam_masks=[
                {"label": "coat rack", "confidence": 0.93, "area_ratio": 0.24}
            ],
        )
    )
    assert res["sam_verified"] is True
    assert res["living_subject_present"] is False
    assert res["chosen_inanimate_label"] == "coat rack"
    # An upright fixture is described as standing in the area, not on a seat.
    assert res["template_id"] == "REASSURE_SHADOW_OR_LIGHT"
    assert "coat rack" in res["spoken_response"]


def test_object_resting_on_a_seat_still_uses_the_seat_template():
    res = asyncio.run(
        run_reality_check_pipeline(
            user_query="Is someone sitting in that chair?",
            image_bytes=None,
            simulated_sam_masks=[
                {"label": "coat", "confidence": 0.93, "area_ratio": 0.24}
            ],
        )
    )
    assert res["template_id"] == "REASSURE_OBJECT_ON_SEAT"
    assert "in this photo" in res["spoken_response"]
    assert "cannot confirm" in res["spoken_response"]


# --------------------------------------------------------------------------
# Defect 3 & 4: demo timeline truncated, no fall, protein conflict invisible
# --------------------------------------------------------------------------
def test_demo_seed_covers_the_full_day_and_every_pipeline():
    with TestClient(app) as client:
        wiped = client.delete("/api/v1/patient/data", headers=DEVICE_HEADERS)
        headers = {**DEVICE_HEADERS, "X-Cadence-Data-Generation": str(wiped.json()["data_generation"])}
        assert client.post("/api/v1/demo/seed", headers=headers).status_code == 200
        rep = client.get("/api/v1/report/neurologist", headers=DEVICE_HEADERS).json()

    labels = [b["label_hhmm"] for b in rep["buckets_24h"]]
    assert len(labels) == 48
    assert rep["report_metadata"]["window_end_utc"] == rep["report_metadata"]["generated_at_utc"]

    # Every pipeline leaves a trace a judge can point at.
    assert rep["fog_events"], "Pipeline 1 produced no rows"
    assert rep["fall_events"], "Pipeline 2 produced no rows"
    assert rep["medication_logs"], "Pipeline 3 produced no rows"
    assert rep["reality_checks"], "Pipeline 4 produced no rows"
    assert rep["handwriting_logs"], "Pipeline 5 produced no rows"
    assert len(rep["motor_exams"]) >= 3, "Pipeline 6 needs OFF, ON and evening exams"

    # The seeded fall resolves on check-in, so it must not inflate confirmed
    # falls, and must not disappear from the report either.
    stats = rep["summary_stats"]
    assert stats["fall_count"] == 0
    assert stats["fall_candidate_resolved_count"] == 1

    # The steak meal normalizes against the plate rather than defaulting to 1.0x.
    meal = [m for m in rep["medication_logs"] if m["event_type"] == "meal_logged"][0]
    assert meal["plate_detected"] == 1
    assert meal["conflict_detected"] == 1
    assert meal["estimated_protein_grams"] > 30.0

    # The reality check returns a grounded object, never the generic fallback.
    rc = rep["reality_checks"][0]
    assert rc["template_id"] != "REASSURE_EMPTY_SPACE"
    assert rc["chosen_inanimate_label"] == "coat rack"

    # The conflict is visible on the diary ribbon, not just in the meal row.
    assert any(b["protein_conflict_active"] for b in rep["buckets_24h"])


def test_demo_seed_is_idempotent():
    """Re-seeding during a live demo must not double-count or error."""
    with TestClient(app) as client:
        client.delete("/api/v1/patient/data", headers=DEVICE_HEADERS)
        client.post("/api/v1/demo/seed", headers=DEVICE_HEADERS)
        first = client.get("/api/v1/report/neurologist", headers=DEVICE_HEADERS).json()
        client.post("/api/v1/demo/seed", headers=DEVICE_HEADERS)
        second = client.get("/api/v1/report/neurologist", headers=DEVICE_HEADERS).json()

    assert len(second["fog_events"]) == len(first["fog_events"])
    assert len(second["motor_exams"]) == len(first["motor_exams"])
    assert len(second["fall_events"]) == len(first["fall_events"])


# --------------------------------------------------------------------------
# Defect 5: ON/OFF delta used a WEARING_OFF trough as the OFF baseline
# --------------------------------------------------------------------------
def test_exam_delta_prefers_a_true_off_baseline_over_a_later_wearing_off():
    """
    Rows arrive newest-first. A later WEARING_OFF exam must not shadow a genuine
    OFF exam, which would understate the measured levodopa response.
    """
    exam_rows = [
        {
            "timestamp_utc": "2026-10-26T19:30:00Z",
            "medication_state_label": "WEARING_OFF",
            "composite_motor_score": 59.1,
            "voice_score": 60.0,
            "handwriting_score": 70.0,
            "gait_score": 50.0,
            "walk_fog_count": 0,
            "walk_mean_fi": 1.0,
            "handwriting_opencv_decay_pct": -10.0,
            "voice_mean_dbfs": -22.0,
        },
        {
            "timestamp_utc": "2026-10-26T09:15:00Z",
            "medication_state_label": "ON",
            "composite_motor_score": 99.3,
            "voice_score": 98.0,
            "handwriting_score": 97.8,
            "gait_score": 100.0,
            "walk_fog_count": 0,
            "walk_mean_fi": 0.7,
            "handwriting_opencv_decay_pct": -6.0,
            "voice_mean_dbfs": -15.0,
        },
        {
            "timestamp_utc": "2026-10-26T07:30:00Z",
            "medication_state_label": "OFF",
            "composite_motor_score": 42.1,
            "voice_score": 79.8,
            "handwriting_score": 58.4,
            "gait_score": 0.0,
            "walk_fog_count": 2,
            "walk_mean_fi": 2.95,
            "handwriting_opencv_decay_pct": -31.0,
            "voice_mean_dbfs": -25.5,
        },
    ]
    tl = build_24h_diary_timeline([], [], [], [], [], exam_rows, reference_end_utc=datetime(2026,10,26,20,tzinfo=timezone.utc))
    delta = tl["exam_on_vs_off_delta"]
    assert delta is not None
    assert delta["off_baseline_state"] == "OFF"
    assert delta["off_composite"] == pytest.approx(42.1)
    assert delta["composite_improvement_pts"] == pytest.approx(57.2, abs=0.05)


def test_exam_delta_uses_wearing_off_only_when_no_true_off_exists():
    exam_rows = [
        {
            "timestamp_utc": "2026-10-26T19:30:00Z",
            "medication_state_label": "WEARING_OFF",
            "composite_motor_score": 59.1,
            "voice_score": 60.0,
            "handwriting_score": 70.0,
            "gait_score": 50.0,
            "walk_fog_count": 0,
            "walk_mean_fi": 1.0,
            "handwriting_opencv_decay_pct": -10.0,
            "voice_mean_dbfs": -22.0,
        },
        {
            "timestamp_utc": "2026-10-26T09:15:00Z",
            "medication_state_label": "ON",
            "composite_motor_score": 99.3,
            "voice_score": 98.0,
            "handwriting_score": 97.8,
            "gait_score": 100.0,
            "walk_fog_count": 0,
            "walk_mean_fi": 0.7,
            "handwriting_opencv_decay_pct": -6.0,
            "voice_mean_dbfs": -15.0,
        },
    ]
    delta = build_24h_diary_timeline([], [], [], [], [], exam_rows, reference_end_utc=datetime(2026,10,26,20,tzinfo=timezone.utc))["exam_on_vs_off_delta"]
    assert delta["off_baseline_state"] == "WEARING_OFF"
    assert delta["off_composite"] == pytest.approx(59.1)


# --------------------------------------------------------------------------
# Defect 6: gather webhook acknowledged alerts for unknown event_uuids
# --------------------------------------------------------------------------
def test_gather_webhook_rejects_an_unknown_event_uuid():
    """
    The webhook is public, authenticated only by X-Twilio-Signature. A forged or
    stale callback naming a fall that does not exist must never be reported as
    an acknowledgement.
    """
    mgr = FallEscalationManager()
    res = asyncio.run(mgr.handle_gather_webhook("no-such-fall-uuid", "1"))
    assert res["acknowledged"] is False
    assert res["reason"] == "unknown_event"


def test_gather_webhook_ignores_digits_other_than_one():
    mgr = FallEscalationManager()
    res = asyncio.run(mgr.handle_gather_webhook("whatever", "9"))
    assert res["acknowledged"] is False


# --------------------------------------------------------------------------
# Defect 7: retry loop ran ~90s past the documented 15-minute cap
# --------------------------------------------------------------------------
def test_retry_loop_is_bounded_by_the_wall_clock_window(monkeypatch):
    """
    The 90s secondary delay is inside the 15-minute window. Counting 15 separate
    60s attempts after it overran the window; the loop must stop at the deadline
    and then mark the alert exhausted.
    """
    monkeypatch.setattr(settings, "secondary_escalation_delay_sec", 0.05)
    monkeypatch.setattr(settings, "retry_interval_sec", 0.05)
    monkeypatch.setattr(settings, "max_retry_attempts", 100)
    monkeypatch.setattr(settings, "retry_window_sec", 0.3)
    monkeypatch.setattr(settings, "caregiver_secondary_phone", "+15550002222")

    async def scenario():
        mgr = FallEscalationManager()
        payload = FallEventCreate(
            event_uuid="retry-window-001",
            peak_impact_g=3.9,
            peak_jerk_gs=48.0,
            post_impact_tilt_deg=74.0,
        )
        await mgr.ingest_fall_event("default_patient", payload, start_background_retry=True)
        task = mgr._active_tasks.get("retry-window-001")
        await asyncio.wait_for(task, timeout=5.0)
        return await fetch_all(
            "SELECT contact_role, delivery_status, retry_count FROM caregiver_alerts "
            "WHERE fall_event_uuid = ? ORDER BY id",
            ("retry-window-001",),
        )

    rows = asyncio.run(scenario())
    assert rows, "the loop must have dispatched at least once"
    assert all(r["delivery_status"] == "exhausted_15m" for r in rows)
    # 0.3s window at 0.05s per retry cannot reach the 100-attempt ceiling.
    assert max(r["retry_count"] for r in rows) < 100


def test_retry_loop_alternates_between_secondary_and_primary(monkeypatch):
    """
    The spec calls for an alternating retry loop. Pinning every retry to the
    secondary contact would abandon a primary caregiver who was briefly busy.
    """
    monkeypatch.setattr(settings, "secondary_escalation_delay_sec", 0.01)
    monkeypatch.setattr(settings, "retry_interval_sec", 0.01)
    monkeypatch.setattr(settings, "max_retry_attempts", 4)
    monkeypatch.setattr(settings, "retry_window_sec", 5.0)
    monkeypatch.setattr(settings, "caregiver_secondary_phone", "+15550002222")

    async def scenario():
        mgr = FallEscalationManager()
        payload = FallEventCreate(
            event_uuid="retry-alternate-001",
            peak_impact_g=3.9,
            peak_jerk_gs=48.0,
            post_impact_tilt_deg=74.0,
        )
        await mgr.ingest_fall_event("default_patient", payload, start_background_retry=True)
        await asyncio.wait_for(mgr._active_tasks["retry-alternate-001"], timeout=5.0)
        return await fetch_all(
            "SELECT contact_role, retry_count FROM caregiver_alerts "
            "WHERE fall_event_uuid = ? AND retry_count > 0 ORDER BY retry_count",
            ("retry-alternate-001",),
        )

    rows = asyncio.run(scenario())
    roles = [r["contact_role"] for r in rows]
    assert roles[0] == "secondary", "first retry escalates to the secondary contact"
    assert "primary" in roles, "later retries must come back to the primary contact"


def test_acknowledgement_during_the_window_stops_the_loop(monkeypatch):
    monkeypatch.setattr(settings, "secondary_escalation_delay_sec", 0.05)
    monkeypatch.setattr(settings, "retry_interval_sec", 0.05)
    monkeypatch.setattr(settings, "max_retry_attempts", 50)
    monkeypatch.setattr(settings, "retry_window_sec", 5.0)

    async def scenario():
        mgr = FallEscalationManager()
        payload = FallEventCreate(
            event_uuid="retry-ack-001",
            peak_impact_g=3.9,
            peak_jerk_gs=48.0,
            post_impact_tilt_deg=74.0,
        )
        await mgr.ingest_fall_event("default_patient", payload, start_background_retry=True)
        await asyncio.sleep(0.01)
        ack = await mgr.handle_gather_webhook("retry-ack-001", "1")
        await asyncio.sleep(0.3)
        rows = await fetch_all(
            "SELECT delivery_status FROM caregiver_alerts WHERE fall_event_uuid = ?",
            ("retry-ack-001",),
        )
        return ack, rows

    ack, rows = asyncio.run(scenario())
    assert ack["acknowledged"] is True
    assert all(r["delivery_status"] == "acknowledged_by_caregiver" for r in rows)
    assert not any(r["delivery_status"] == "exhausted_15m" for r in rows)
