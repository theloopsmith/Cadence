import asyncio
import time
import logging
from datetime import datetime, timezone
from typing import Any, Dict, Optional

from app.clients.twilio_client import mask_phone, twilio_client
from app.config import settings
from app.db import claim_caregiver_alert, execute_write, execute_patient_write, fetch_all, fetch_one, DataGenerationChanged, data_generation_sync
from app.models import FallEventCreate
from app.services import fall_durability as durable
from app.services.delivery_evidence import delivery_evidence
from fastapi import HTTPException

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
        self._recovery_task = None

    def _primary_phone(self) -> str:
        # Development with no contact uses a placeholder so the simulated path is
        # exercised; production returns "" and the dispatch reports "unconfigured".
        return settings.caregiver_primary_phone or ("" if settings.is_production else "+15550001111")

    async def _require_owned_event(self, patient_id: str, event_uuid: str) -> None:
        row = await fetch_one("SELECT patient_id FROM fall_events WHERE event_uuid = ?", (event_uuid,))
        if row and row["patient_id"] != patient_id:
            raise HTTPException(status_code=404, detail="Fall event not found.")

    def evaluate_suppression_gate(self, payload: FallEventCreate) -> str:
        """
        Determines whether a fall event should be dispatched or suppressed.
        - Distress keywords or vocal groans (vocal_activity_detected) ALWAYS escalate!
        - Unworn drop suppression is DISABLED by default (settings.enable_unworn_drop_suppression == False).
        """
        if payload.status in {"canceled_false_alarm", "candidate_check_in_pending"}:
            return payload.status

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
        data_generation: int = 0,
    ) -> Dict[str, Any]:
        """
        1. Evaluates fail-safe wear/groan gate.
        2. Performs synchronous SQLite commit BEFORE calling Twilio API.
        3. Dispatches Primary SMS (with GPS Maps link) + Voice Call (<Gather numDigits='1'>).

        The device posts the same event_uuid more than once: the Stage 3
        candidate, then the check-in outcome, plus any queue retries. Only a
        candidate row may be overwritten, and only the request that moves the
        row out of 'confirmed_waiting_dispatch' contacts caregivers.
        """
        await self._require_owned_event(patient_id, payload.event_uuid)
        effective_status = self.evaluate_suppression_gate(payload)
        stored_status = await durable.persist(
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
            WHERE fall_events.status = 'candidate_check_in_pending'
              AND fall_events.patient_id = excluded.patient_id
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
            patient_id, payload.event_uuid, effective_status, data_generation=data_generation,
        )

        await self._require_owned_event(patient_id, payload.event_uuid)
        if effective_status == 'canceled_false_alarm':
            return await self.cancel_dispatched_fall(patient_id, payload.event_uuid, data_generation=data_generation)

        if stored_status in {
            "canceled_false_alarm",
            "suppressed_unworn_drop",
            "candidate_check_in_pending",
        }:
            return {
                "event_uuid": payload.event_uuid,
                "status": stored_status,
                "twilio_dispatched": False,
                "local_siren_active": False,
            }

        primary_phone = self._primary_phone()
        attempt_id = await durable.begin(patient_id, payload.event_uuid, "primary", primary_phone, 0, primary=True)
        claimed = bool(attempt_id)
        fall_row = await fetch_one(
            "SELECT * FROM fall_events WHERE event_uuid = ? AND patient_id = ?", (payload.event_uuid, patient_id)
        )
        if not claimed:
            if not fall_row:
                raise DataGenerationChanged(await asyncio.to_thread(data_generation_sync, patient_id))
            return {
                "event_uuid": payload.event_uuid,
                "status": fall_row["status"],
                "twilio_dispatched": False,
                "provider_accepted": bool(fall_row.get("caregiver_sms_sid") or fall_row.get("caregiver_call_sid")),
                "duplicate": True,
                "local_siren_active": fall_row["status"] == "escalated_twilio",
            }

        # Dispatch from the stored row: the escalation posted after the
        # check-in may carry zeroed impact figures, while the Stage 3
        # candidate recorded the real ones.
        primary_phone = self._primary_phone()
        dispatch_res = await self._dispatch(attempt_id,
            to_phone=primary_phone,
            event_uuid=payload.event_uuid,
            peak_impact_g=float(fall_row["peak_impact_g"]),
            timestamp_utc=str(fall_row["timestamp_utc"]),
            latitude=fall_row.get("latitude"),
            longitude=fall_row.get("longitude"),
        )
        dispatch_res = await durable.finish(attempt_id, dispatch_res)
        if not dispatch_res.get("sms_sid") and not dispatch_res.get("call_sid"):
            # Nothing reached a caregiver. Leave the row waiting so the device
            # queue retries instead of treating a dead Twilio call as delivered.
            await execute_write(
                """
                UPDATE fall_events SET status = 'confirmed_waiting_dispatch'
                WHERE event_uuid = ? AND patient_id = ? AND status = 'escalated_twilio'
                """,
                (payload.event_uuid, patient_id),
            )
            return {
                "event_uuid": payload.event_uuid,
                "status": "confirmed_waiting_dispatch",
                "twilio_dispatched": False,
                "local_siren_active": True,
            }

        await execute_write(
            """
            UPDATE fall_events
            SET caregiver_sms_sid = ?,
                caregiver_call_sid = ?
            WHERE event_uuid = ? AND patient_id = ?
            """,
            (
                dispatch_res["sms_sid"],
                dispatch_res["call_sid"],
                payload.event_uuid,
                patient_id,
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

        if await self._is_resolved(payload.event_uuid):
            resolved_fall = await fetch_one("SELECT status FROM fall_events WHERE event_uuid=?",(payload.event_uuid,))
            resolved_status = 'canceled_by_user' if resolved_fall['status']=='canceled_false_alarm' else 'acknowledged_by_caregiver'
            await execute_write("UPDATE caregiver_alerts SET delivery_status=? WHERE fall_event_uuid=? AND patient_id=?",(resolved_status,payload.event_uuid,patient_id))
            await durable.send_pending_clears(twilio_client)
        if start_background_retry and settings.secondary_escalation_delay_sec > 0 and not await self._is_resolved(payload.event_uuid):
            task = asyncio.create_task(
                self._run_escalation_loop(patient_id, payload.event_uuid)
            )
            self._active_tasks[payload.event_uuid] = task

        return {
            "event_uuid": payload.event_uuid,
            "status": "escalated_twilio",
            "twilio_dispatched": True,
            "provider_accepted": True,
            "sms_sid": dispatch_res["sms_sid"],
            "call_sid": dispatch_res["call_sid"],
            "sms_body": dispatch_res.get("sms_body", ""),
            "local_siren_active": True,
        }

    async def escalate_to_secondary_or_retry_primary(
        self,
        patient_id: str,
        event_uuid: str,
        retry_count: int = 1,
        expected_attempt_no: Optional[int] = None,
    ) -> Dict[str, Any]:
        """
        Escalates to CAREGIVER_SECONDARY_PHONE if configured; if unset, retries Primary.
        """
        await self._require_owned_event(patient_id, event_uuid)
        fall_row = await fetch_one(
            "SELECT * FROM fall_events WHERE event_uuid = ? AND patient_id = ?", (event_uuid, patient_id)
        )
        if not fall_row or fall_row["status"] == "canceled_false_alarm":
            return {"dispatched": False}

        secondary_phone = settings.caregiver_secondary_phone.strip()
        if secondary_phone:
            # Alternate secondary / primary across retries so a caregiver who
            # was briefly unreachable on the first pass is tried again rather
            # than being dropped for the rest of the 15-minute window. The
            # first retry always goes to the secondary contact, as the spec's
            # "escalate to secondary at T+90s" rule requires.
            if retry_count % 2 == 1:
                role = "secondary"
                target_phone = secondary_phone
            else:
                role = "primary"
                target_phone = self._primary_phone()
        else:
            role = "primary"
            target_phone = self._primary_phone()

        now_iso = datetime.now(timezone.utc).isoformat()
        claim_id = await claim_caregiver_alert(
            patient_id=patient_id,
            fall_event_uuid=event_uuid,
            timestamp_utc=now_iso,
            contact_role=role,
            contact_phone_masked=mask_phone(target_phone),
            channel="voice_call",
            retry_count=retry_count,
        )
        if not claim_id:
            return {"dispatched": False, "contact_role": role, "retry_count": retry_count}

        attempt_id = await durable.begin(patient_id, event_uuid, role, target_phone, retry_count, expected_attempt_no=expected_attempt_no)
        if not attempt_id:
            await execute_write("DELETE FROM caregiver_alerts WHERE id=? AND patient_id=?", (claim_id, patient_id))
            return {"dispatched": False}
        res = await self._dispatch(attempt_id,
            to_phone=target_phone,
            event_uuid=event_uuid,
            peak_impact_g=float(fall_row["peak_impact_g"]),
            timestamp_utc=str(fall_row["timestamp_utc"]),
            latitude=fall_row.get("latitude"),
            longitude=fall_row.get("longitude"),
        )
        res = await durable.finish(attempt_id, res)
        if not res.get("sms_sid") and not res.get("call_sid"):
            await execute_write(
                "DELETE FROM caregiver_alerts WHERE id = ? AND patient_id = ?",
                (claim_id, patient_id),
            )
            return {"dispatched": False, "contact_role": role, "retry_count": retry_count}

        await execute_write(
            """
            UPDATE caregiver_alerts
            SET provider_sid = ?, delivery_status = ?
            WHERE id = ? AND patient_id = ?
            """,
            (res.get("call_sid") or res.get("sms_sid") or "", res["delivery_status"], claim_id, patient_id),
        )
        return {"dispatched": True, "contact_role": role, "retry_count": retry_count}

    async def _dispatch(self, attempt_id, **kwargs):
        try:
            return await asyncio.wait_for(
                twilio_client.dispatch_sms_and_call(attempt_id=attempt_id, **kwargs),
                timeout=settings.dispatch_timeout_sec,
            )
        except Exception:
            logging.getLogger('cadence').exception('Caregiver dispatch failed for attempt %s', attempt_id)
            return {"sms_sid": "", "call_sid": "", "delivery_status": "transport_unavailable"}

    async def _callback_attempt(self, event_uuid, call_sid, attempt_id):
        # Signature validation happens at the route; correlation still has to match
        # a committed outbound attempt. Demo callbacks cannot prove real delivery.
        if attempt_id:
            row = await fetch_one("SELECT * FROM fall_attempts WHERE attempt_id=? AND event_uuid=?", (attempt_id,event_uuid))
        else:
            row = await fetch_one("SELECT * FROM fall_attempts WHERE event_uuid=? ORDER BY attempt_no DESC LIMIT 1", (event_uuid,))
            if not (row and row['simulated'] and settings.demo_mode_enabled and not settings.is_production): return None
        if not row: return None
        if not call_sid:
            return row if row['simulated'] and settings.demo_mode_enabled and not settings.is_production else None
        if not call_sid.startswith('CA') or (row['call_sid'] and row['call_sid'] != call_sid): return None
        if row['simulated'] and not call_sid.startswith('CA_SIM_'): return None
        await execute_write("UPDATE fall_attempts SET call_sid=? WHERE attempt_id=? AND (call_sid IS NULL OR call_sid='' OR call_sid=?)",(call_sid,row['attempt_id'],call_sid))
        return row

    async def handle_gather_webhook(self, event_uuid, digits, call_sid=None, attempt_id=None):
        attempt = await self._callback_attempt(event_uuid,call_sid,attempt_id)
        if digits.strip() != '1' or not attempt:
            exists=await fetch_one('SELECT event_uuid FROM fall_events WHERE event_uuid=?',(event_uuid,))
            return {'acknowledged':False,'event_uuid':event_uuid,'reason':'unmatched_attempt' if exists else 'unknown_event'}
        def acknowledge(c):
            job=c.execute('SELECT state FROM fall_jobs WHERE event_uuid=?',(event_uuid,)).fetchone()
            fall=c.execute('SELECT status FROM fall_events WHERE event_uuid=?',(event_uuid,)).fetchone()
            if not job or not fall or fall['status']=='canceled_false_alarm': return False
            c.execute("UPDATE fall_attempts SET acknowledged_at=?,state='acknowledged' WHERE attempt_id=?",(time.time(),attempt['attempt_id']))
            c.execute("UPDATE fall_jobs SET state='resolved' WHERE event_uuid=?",(event_uuid,))
            c.execute("UPDATE caregiver_alerts SET delivery_status='acknowledged_by_caregiver',acknowledged_at_utc=? WHERE fall_event_uuid=? AND delivery_status!='canceled_by_user'",(datetime.now(timezone.utc).isoformat(),event_uuid))
            return True
        accepted=await durable.transact(acknowledge)
        return {'acknowledged':accepted,'event_uuid':event_uuid,'simulated':bool(attempt['simulated'])}

    async def handle_status_webhook(self, event_uuid, call_status, call_sid=None, attempt_id=None):
        attempt=await self._callback_attempt(event_uuid,call_sid,attempt_id)
        if not attempt: return {'escalated':False,'reason':'unmatched_attempt'}
        status=call_status.strip().lower()
        changed=await execute_write("UPDATE fall_attempts SET call_status=? WHERE attempt_id=? AND (call_status IS NULL OR call_status!=?)",(status,attempt['attempt_id'],status))
        if await self._is_resolved(event_uuid): return {'escalated':False,'reason':'already_resolved'}
        if status in TERMINAL_FAILURE_STATUSES and changed:
            res=await self.escalate_to_secondary_or_retry_primary(attempt['patient_id'],event_uuid,1)
            return {'escalated':bool(res.get('dispatched')),**res}
        return {'escalated':False,'call_status':status}

    async def delivery_status(self, patient_id, event_uuid):
        await self._require_owned_event(patient_id,event_uuid)
        job=await fetch_one("SELECT state,next_due,deadline FROM fall_jobs WHERE event_uuid=? AND patient_id=?",(event_uuid,patient_id))
        if not job: raise HTTPException(404,'Fall event not found.')
        attempts=await fetch_all("SELECT attempt_id,attempt_no,state,sms_sid,call_sid,call_status,acknowledged_at,simulated FROM fall_attempts WHERE event_uuid=? AND patient_id=? ORDER BY attempt_no",(event_uuid,patient_id))
        fall=await fetch_one('SELECT * FROM fall_events WHERE event_uuid=? AND patient_id=?',(event_uuid,patient_id))
        return {**delivery_evidence(fall,attempts,job),'job':job,'attempts':attempts}

    async def cancel_dispatched_fall(
        self,
        patient_id: str,
        event_uuid: str,
        data_generation: int = 0,
    ) -> Dict[str, Any]:
        """
        Post-dispatch user cancellation (POST /api/v1/events/fall/{event_uuid}/cancel):
        1. Cancels background retry task.
        2. Marks caregiver_alerts as 'canceled_by_user' and fall_events as 'canceled_false_alarm'.
        3. Sends automated All-Clear SMS to all notified contacts.
        """
        await self._require_owned_event(patient_id, event_uuid)
        existing = await fetch_one(
            "SELECT event_uuid FROM fall_events WHERE event_uuid = ? AND patient_id = ?",
            (event_uuid, patient_id),
        )
        if existing is None:
            # The phone can upload the cancel before the fall when the queue
            # drains out of order. The tombstone makes the later fall a no-op.
            from app.security import AuthContext
            inserted = await execute_patient_write(AuthContext('device_writer', patient_id, data_generation),
                """
                INSERT OR IGNORE INTO fall_events (
                    patient_id, event_uuid, timestamp_utc, peak_impact_g, peak_jerk_gs,
                    post_impact_tilt_deg, pre_impact_wear_rms_g, pre_impact_resp_power,
                    worn_pre_impact, status, local_siren_activated
                ) VALUES (?, ?, ?, 0, 0, 0, 0, 0, 1, 'canceled_false_alarm', 0)
                """,
                (patient_id, event_uuid, datetime.now(timezone.utc).isoformat()),
            )
            if inserted:
                await self._ensure_legacy_jobs()
                await durable.cancel(patient_id, event_uuid, data_generation=data_generation)
                return {
                    "event_uuid": event_uuid,
                    "delivery_status": "canceled_by_user",
                    "status": "canceled_false_alarm", "twilio_dispatched": False,
                    "all_clear_sms_sent": 0,
                }

        await self._require_owned_event(patient_id, event_uuid)
        await durable.cancel(patient_id, event_uuid, data_generation=data_generation)
        task = self._active_tasks.pop(event_uuid, None)
        if task: task.cancel()
        all_clear_sent = await durable.send_pending_clears(twilio_client)
        return {
            "event_uuid": event_uuid,
            "delivery_status": "canceled_by_user",
            "status": "canceled_false_alarm", "twilio_dispatched": False,
            "all_clear_sms_sent": all_clear_sent,
        }

    async def _is_resolved(self, event_uuid: str) -> bool:
        """True once any contact acknowledged the alert or the wearer canceled it."""
        fall = await fetch_one("SELECT status FROM fall_events WHERE event_uuid=?", (event_uuid,))
        if not fall or fall["status"] in {"canceled_false_alarm", "suppressed_unworn_drop"}:
            return True
        job = await fetch_one("SELECT state FROM fall_jobs WHERE event_uuid=?", (event_uuid,))
        if job and job["state"] in {"resolved", "exhausted"}:
            return True
        resolved = await fetch_one(
            """
            SELECT id FROM caregiver_alerts
            WHERE fall_event_uuid = ?
              AND delivery_status IN ('acknowledged_by_caregiver', 'canceled_by_user')
            """,
            (event_uuid,),
        )
        return resolved is not None

    async def _ensure_legacy_jobs(self):
        # Migrate pre-outbox rows without altering the original incident time/window.
        def migrate(c):
            now = time.time()
            rows = c.execute("SELECT f.*, MIN(a.timestamp_utc) AS dispatched_at FROM fall_events f LEFT JOIN caregiver_alerts a ON a.fall_event_uuid=f.event_uuid WHERE NOT EXISTS (SELECT 1 FROM fall_jobs j WHERE j.event_uuid=f.event_uuid) GROUP BY f.event_uuid").fetchall()
            for row in rows:
                resolved = row['status'] in ('canceled_false_alarm','suppressed_unworn_drop')
                candidate = row['status']=='candidate_check_in_pending'
                try: start=_parse_utc(row['dispatched_at'] or row['timestamp_utc']).timestamp()
                except (ValueError,TypeError): start=now
                due=start+settings.fall_check_in_sec if candidate else now
                c.execute("INSERT INTO fall_jobs(event_uuid,patient_id,state,next_due,deadline,attempt_no) VALUES(?,?,?,?,?,?)",(row['event_uuid'],row['patient_id'],'resolved' if resolved else ('check_in' if candidate else 'pending'),due,start+settings.retry_window_sec, 0 if row['caregiver_call_sid'] or row['caregiver_sms_sid'] else -1))
        await durable.transact(migrate)

    async def recover_due_once(self):
        rows=await durable.due_jobs()
        for job in rows:
            # One bad row must not stop the sweep for every other wearer.
            try:
                await self._recover_job(job)
            except asyncio.CancelledError:
                raise
            except Exception:
                logging.getLogger('cadence').exception('Fall recovery failed for %s; job retained', job['event_uuid'])
        await durable.send_pending_clears(twilio_client)
        return [r['event_uuid'] for r in rows]

    async def _recover_job(self, job):
        event=await fetch_one("SELECT * FROM fall_events WHERE event_uuid=? AND patient_id=?", (job['event_uuid'],job['patient_id']))
        if not event or await self._is_resolved(job['event_uuid']): return
        if job['attempt_no'] >= settings.max_retry_attempts:
            await execute_write("UPDATE fall_jobs SET state='exhausted' WHERE event_uuid=?", (job['event_uuid'],))
            return
        # No attempt was made yet: dispatch the persisted original candidate.
        if job['attempt_no'] < 0 and not event.get('caregiver_call_sid') and not event.get('caregiver_sms_sid'):
            # due_jobs already promotes timed-out candidates transactionally.
            # Never reset event state from a potentially stale worker snapshot.
            fields={k:v for k,v in event.items() if k in FallEventCreate.model_fields and v is not None}
            fields['status']='confirmed_waiting_dispatch'
            # The server owns this recovery: it writes at the wearer's current
            # data generation, not the phone's. A past "Reset Diary Data" must
            # never fence the dispatch of a later fall.
            generation=await asyncio.to_thread(data_generation_sync, job['patient_id'])
            await self.ingest_fall_event(job['patient_id'],FallEventCreate(**fields),False,data_generation=generation)
        else:
            await self.escalate_to_secondary_or_retry_primary(job['patient_id'],job['event_uuid'],int(job['attempt_no'])+1, expected_attempt_no=int(job['attempt_no']))

    async def resume_open_escalations(self):
        await self._ensure_legacy_jobs()
        rows=await fetch_all("SELECT event_uuid,patient_id FROM fall_jobs WHERE state NOT IN ('resolved','exhausted')")
        await durable.due_jobs()  # close expired jobs, promote overdue check-ins
        resumed=[]
        for row in rows:
            if await self._is_resolved(row['event_uuid']): continue
            task=self._active_tasks.get(row['event_uuid'])
            if task is None or task.done():
                self._active_tasks[row['event_uuid']]=asyncio.create_task(self._run_escalation_loop(row['patient_id'],row['event_uuid']))
            resumed.append(row['event_uuid'])
        if self._recovery_task is None or self._recovery_task.done():
            self._recovery_task=asyncio.create_task(self._watch_recovery())
        return resumed

    async def _watch_recovery(self):
        # Retention used to run only at startup; a server that stays up for
        # weeks never purged. It now runs once a day from this loop.
        next_purge = time.time() + 24 * 3600
        while True:
            try:
                await self.recover_due_once()
                if time.time() >= next_purge:
                    next_purge = time.time() + 24 * 3600
                    from app.db import purge_expired_telemetry
                    await purge_expired_telemetry()
            except asyncio.CancelledError:
                raise
            except Exception:
                logging.getLogger('cadence').exception('Fall recovery sweep failed; persisted jobs retained')
            await asyncio.sleep(settings.recovery_poll_sec)

    async def _run_escalation_loop(self, patient_id, event_uuid, delay_sec=None, window_sec=None, attempts_already=0):
        try:
            while not await self._is_resolved(event_uuid):
                await self.recover_due_once()
                await asyncio.sleep(min(settings.recovery_poll_sec, max(0.01, settings.retry_interval_sec)))
        except asyncio.CancelledError:
            return

    async def close(self):
        tasks=list(self._active_tasks.values())
        if self._recovery_task: tasks.append(self._recovery_task)
        for task in tasks: task.cancel()
        if tasks: await asyncio.gather(*tasks,return_exceptions=True)
        self._active_tasks.clear()
        self._recovery_task=None


def _parse_utc(value):
    parsed=datetime.fromisoformat(value.replace('Z','+00:00'))
    return parsed.replace(tzinfo=timezone.utc) if parsed.tzinfo is None else parsed


fall_escalation_manager = FallEscalationManager()
