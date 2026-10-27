import asyncio
from datetime import datetime, timezone
from typing import Any, Dict, Optional

from app.clients.twilio_client import mask_phone, twilio_client
from app.config import settings
from app.db import execute_write, fetch_all, fetch_one
from app.models import FallEventCreate

TERMINAL_FAILURE_STATUSES = {"busy", "no-answer", "failed", "canceled"}


class FallEscalationManager:
    """
    Manages fail-safe fall persistence, signed Twilio webhook handling,
    secondary caregiver escalation (immediate on terminal status OR T + 90s),
    60s alternating retry loop (15m cap), and post-dispatch user cancellation
    with automated All-Clear SMS.
    """

    def __init__(self) -> None:
        self._active_tasks: Dict[str, asyncio.Task] = {}

    def evaluate_suppression_gate(self, payload: FallEventCreate) -> str:
        """
        Determines whether a fall event should be dispatched or suppressed.
        - Distress keywords or vocal groans (vocal_activity_detected) ALWAYS escalate!
        - Unworn drop suppression is DISABLED by default (settings.enable_unworn_drop_suppression == False).
        """
        if payload.status == "canceled_false_alarm":
            return "canceled_false_alarm"

        if payload.distress_keyword_detected or payload.vocal_activity_detected:
            return "confirmed_waiting_dispatch"

        if (
            settings.enable_unworn_drop_suppression
            and not payload.worn_pre_impact
            and not payload.vocal_activity_detected
            and not payload.distress_keyword_detected
        ):
            return "suppressed_unworn_drop"

        return "confirmed_waiting_dispatch"

    async def ingest_fall_event(
        self,
        patient_id: str,
        payload: FallEventCreate,
        start_background_retry: bool = True,
    ) -> Dict[str, Any]:
        """
        1. Evaluates fail-safe wear/groan gate.
        2. Performs synchronous SQLite commit BEFORE calling Twilio API.
        3. Dispatches Primary SMS (with GPS Maps link) + Voice Call (<Gather numDigits='1'>).
        """
        effective_status = self.evaluate_suppression_gate(payload)

        await execute_write(
            """
            INSERT INTO fall_events (
                patient_id, event_uuid, timestamp_utc, peak_impact_g, peak_jerk_gs,
                post_impact_tilt_deg, pre_impact_wear_rms_g, pre_impact_resp_power,
                worn_pre_impact, latitude, longitude, horizontal_accuracy_m,
                status, cancel_transcript, local_siren_activated
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(event_uuid) DO UPDATE SET
                status = excluded.status,
                cancel_transcript = excluded.cancel_transcript
            """,
            (
                patient_id,
                payload.event_uuid,
                payload.timestamp_utc,
                payload.peak_impact_g,
                payload.peak_jerk_gs,
                payload.post_impact_tilt_deg,
                payload.pre_impact_wear_rms_g,
                payload.pre_impact_resp_power,
                1 if payload.worn_pre_impact else 0,
                payload.latitude,
                payload.longitude,
                payload.horizontal_accuracy_m,
                effective_status,
                payload.cancel_transcript,
                1 if payload.local_siren_activated else 0,
            ),
        )

        if effective_status in {"canceled_false_alarm", "suppressed_unworn_drop"}:
            return {
                "event_uuid": payload.event_uuid,
                "status": effective_status,
                "twilio_dispatched": False,
                "local_siren_active": False,
            }

        # Synchronous audit row BEFORE external Twilio call
        primary_phone = settings.caregiver_primary_phone or "+15550001111"
        dispatch_res = await twilio_client.dispatch_sms_and_call(
            to_phone=primary_phone,
            event_uuid=payload.event_uuid,
            peak_impact_g=payload.peak_impact_g,
            timestamp_utc=payload.timestamp_utc,
            latitude=payload.latitude,
            longitude=payload.longitude,
        )

        await execute_write(
            """
            UPDATE fall_events
            SET status = 'escalated_twilio',
                caregiver_sms_sid = ?,
                caregiver_call_sid = ?
            WHERE event_uuid = ?
            """,
            (
                dispatch_res["sms_sid"],
                dispatch_res["call_sid"],
                payload.event_uuid,
            ),
        )

        await execute_write(
            """
            INSERT INTO caregiver_alerts (
                patient_id, fall_event_uuid, timestamp_utc, contact_role,
                contact_phone_masked, channel, provider_sid, delivery_status, retry_count
            ) VALUES (?, ?, ?, 'primary', ?, 'voice_call', ?, ?, 0)
            """,
            (
                patient_id,
                payload.event_uuid,
                datetime.now(timezone.utc).isoformat(),
                mask_phone(primary_phone),
                dispatch_res["call_sid"],
                dispatch_res["delivery_status"],
            ),
        )

        if start_background_retry and settings.secondary_escalation_delay_sec > 0:
            task = asyncio.create_task(
                self._run_escalation_loop(patient_id, payload)
            )
            self._active_tasks[payload.event_uuid] = task

        return {
            "event_uuid": payload.event_uuid,
            "status": "escalated_twilio",
            "twilio_dispatched": True,
            "sms_sid": dispatch_res["sms_sid"],
            "call_sid": dispatch_res["call_sid"],
            "sms_body": dispatch_res["sms_body"],
            "local_siren_active": True,
        }

    async def escalate_to_secondary_or_retry_primary(
        self,
        patient_id: str,
        event_uuid: str,
        retry_count: int = 1,
    ) -> Dict[str, Any]:
        """
        Escalates to CAREGIVER_SECONDARY_PHONE if configured; if unset, retries Primary.
        """
        fall_row = await fetch_one(
            "SELECT * FROM fall_events WHERE event_uuid = ?", (event_uuid,)
        )
        if not fall_row:
            return {"dispatched": False}

        secondary_phone = settings.caregiver_secondary_phone.strip()
        if secondary_phone:
            role = "secondary"
            target_phone = secondary_phone
        else:
            role = "primary"
            target_phone = settings.caregiver_primary_phone or "+15550001111"

        res = await twilio_client.dispatch_sms_and_call(
            to_phone=target_phone,
            event_uuid=event_uuid,
            peak_impact_g=float(fall_row["peak_impact_g"]),
            timestamp_utc=str(fall_row["timestamp_utc"]),
            latitude=fall_row.get("latitude"),
            longitude=fall_row.get("longitude"),
        )

        await execute_write(
            """
            INSERT INTO caregiver_alerts (
                patient_id, fall_event_uuid, timestamp_utc, contact_role,
                contact_phone_masked, channel, provider_sid, delivery_status, retry_count
            ) VALUES (?, ?, ?, ?, ?, 'voice_call', ?, ?, ?)
            """,
            (
                patient_id,
                event_uuid,
                datetime.now(timezone.utc).isoformat(),
                role,
                mask_phone(target_phone),
                res["call_sid"],
                res["delivery_status"],
                retry_count,
            ),
        )
        return {"dispatched": True, "contact_role": role, "retry_count": retry_count}

    async def handle_gather_webhook(
        self,
        event_uuid: str,
        digits: str,
    ) -> Dict[str, Any]:
        """Handles caregiver pressing '1' on Twilio <Gather> webhook."""
        if digits.strip() == "1":
            now_iso = datetime.now(timezone.utc).isoformat()
            await execute_write(
                """
                UPDATE caregiver_alerts
                SET delivery_status = 'acknowledged_by_caregiver',
                    acknowledged_at_utc = ?
                WHERE fall_event_uuid = ?
                """,
                (now_iso, event_uuid),
            )
            task = self._active_tasks.pop(event_uuid, None)
            if task:
                task.cancel()
            return {"acknowledged": True, "event_uuid": event_uuid}
        return {"acknowledged": False, "event_uuid": event_uuid}

    async def handle_status_webhook(
        self,
        event_uuid: str,
        call_status: str,
    ) -> Dict[str, Any]:
        """
        Handles Twilio call status webhook. If primary call fails with a terminal status
        (busy, no-answer, failed, canceled) and not yet acknowledged, escalates immediately!
        """
        status_lower = call_status.strip().lower()
        fall_row = await fetch_one(
            "SELECT * FROM fall_events WHERE event_uuid = ?", (event_uuid,)
        )
        if not fall_row:
            return {"escalated": False}

        acked = await fetch_one(
            """
            SELECT id FROM caregiver_alerts
            WHERE fall_event_uuid = ?
              AND delivery_status IN ('acknowledged_by_caregiver', 'canceled_by_user')
            """,
            (event_uuid,),
        )
        if acked:
            return {"escalated": False, "reason": "already_resolved"}

        if status_lower in TERMINAL_FAILURE_STATUSES:
            res = await self.escalate_to_secondary_or_retry_primary(
                patient_id=str(fall_row["patient_id"]),
                event_uuid=event_uuid,
                retry_count=1,
            )
            return {"escalated": True, **res}

        return {"escalated": False, "call_status": status_lower}

    async def cancel_dispatched_fall(
        self,
        patient_id: str,
        event_uuid: str,
    ) -> Dict[str, Any]:
        """
        Post-dispatch user cancellation (POST /api/v1/events/fall/{event_uuid}/cancel):
        1. Cancels background retry task.
        2. Marks caregiver_alerts as 'canceled_by_user' and fall_events as 'canceled_false_alarm'.
        3. Sends automated All-Clear SMS to all notified contacts.
        """
        task = self._active_tasks.pop(event_uuid, None)
        if task:
            task.cancel()

        await execute_write(
            "UPDATE fall_events SET status = 'canceled_false_alarm' WHERE event_uuid = ? AND patient_id = ?",
            (event_uuid, patient_id),
        )
        await execute_write(
            "UPDATE caregiver_alerts SET delivery_status = 'canceled_by_user' WHERE fall_event_uuid = ? AND patient_id = ?",
            (event_uuid, patient_id),
        )

        alerts = await fetch_all(
            "SELECT DISTINCT contact_role FROM caregiver_alerts WHERE fall_event_uuid = ? AND patient_id = ?",
            (event_uuid, patient_id),
        )
        notified_roles = {r["contact_role"] for r in alerts}
        all_clear_sent = 0

        for role in sorted(notified_roles):
            phone = (
                settings.caregiver_secondary_phone
                if role == "secondary" and settings.caregiver_secondary_phone
                else (settings.caregiver_primary_phone or "+15550001111")
            )
            clear_res = await twilio_client.send_all_clear_sms(phone, event_uuid)
            await execute_write(
                """
                INSERT INTO caregiver_alerts (
                    patient_id, fall_event_uuid, timestamp_utc, contact_role,
                    contact_phone_masked, channel, provider_sid, delivery_status, retry_count
                ) VALUES (?, ?, ?, ?, ?, 'all_clear_sms', ?, 'canceled_by_user', 0)
                """,
                (
                    patient_id,
                    event_uuid,
                    datetime.now(timezone.utc).isoformat(),
                    role,
                    mask_phone(phone),
                    clear_res["sms_sid"],
                ),
            )
            all_clear_sent += 1

        return {
            "event_uuid": event_uuid,
            "delivery_status": "canceled_by_user",
            "all_clear_sms_sent": all_clear_sent,
        }

    async def _run_escalation_loop(
        self,
        patient_id: str,
        payload: FallEventCreate,
    ) -> None:
        """
        Waits 90s for Primary keypress '1'; if unacknowledged, escalates to Secondary
        (or retries Primary) and repeats every 60s up to 15 attempts (15m cap).
        After 15m exhaustion, marks 'exhausted_15m' while local iPhone speaker siren persists.
        """
        try:
            await asyncio.sleep(settings.secondary_escalation_delay_sec)
            for attempt in range(1, settings.max_retry_attempts + 1):
                resolved = await fetch_one(
                    """
                    SELECT id FROM caregiver_alerts
                    WHERE fall_event_uuid = ?
                      AND delivery_status IN ('acknowledged_by_caregiver', 'canceled_by_user')
                    """,
                    (payload.event_uuid,),
                )
                if resolved:
                    return
                await self.escalate_to_secondary_or_retry_primary(
                    patient_id=patient_id,
                    event_uuid=payload.event_uuid,
                    retry_count=attempt,
                )
                await asyncio.sleep(settings.retry_interval_sec)

            # 15m cap reached: mark exhausted_15m; local iPhone speaker siren continues
            await execute_write(
                """
                UPDATE caregiver_alerts
                SET delivery_status = 'exhausted_15m'
                WHERE fall_event_uuid = ?
                  AND delivery_status NOT IN ('acknowledged_by_caregiver', 'canceled_by_user')
                """,
                (payload.event_uuid,),
            )
        except asyncio.CancelledError:
            return


fall_escalation_manager = FallEscalationManager()
