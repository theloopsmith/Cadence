"""Transactional fall outbox. External delivery is at-least-once, never exactly-once.

A lease fences stale workers; an attempt is committed before any provider call.
Expired attempts are preserved as unknown and retried within the original window.
"""
import asyncio
import time
import uuid
from app.config import settings
from app.db import _connect_sync

SCHEMA = """
CREATE TABLE IF NOT EXISTS fall_jobs (
 event_uuid TEXT PRIMARY KEY REFERENCES fall_events(event_uuid), patient_id TEXT NOT NULL,
 state TEXT NOT NULL, next_due REAL NOT NULL, deadline REAL NOT NULL,
 lease_until REAL NOT NULL DEFAULT 0, lease_token TEXT, attempt_no INTEGER NOT NULL DEFAULT -1
);
CREATE INDEX IF NOT EXISTS idx_fall_jobs_due ON fall_jobs(state,next_due,lease_until);
CREATE TABLE IF NOT EXISTS fall_attempts (
 attempt_id TEXT PRIMARY KEY, event_uuid TEXT NOT NULL REFERENCES fall_events(event_uuid),
 patient_id TEXT NOT NULL, attempt_no INTEGER NOT NULL, contact_role TEXT NOT NULL,
 to_phone TEXT NOT NULL, started_at REAL NOT NULL, state TEXT NOT NULL,
 sms_sid TEXT, call_sid TEXT, call_status TEXT, acknowledged_at REAL,
 simulated INTEGER NOT NULL DEFAULT 0, UNIQUE(event_uuid,attempt_no)
);
CREATE TABLE IF NOT EXISTS fall_clear_jobs (
 event_uuid TEXT NOT NULL REFERENCES fall_events(event_uuid), patient_id TEXT NOT NULL,
 to_phone TEXT NOT NULL, state TEXT NOT NULL DEFAULT 'pending', next_due REAL NOT NULL,
 lease_until REAL NOT NULL DEFAULT 0, lease_token TEXT, provider_sid TEXT,
 PRIMARY KEY(event_uuid,to_phone)
);
"""


def transaction(fn):
    conn = _connect_sync()
    try:
        conn.execute('PRAGMA synchronous=FULL')
        conn.execute('BEGIN IMMEDIATE')
        value = fn(conn)
        conn.commit()
        return value
    except BaseException:
        conn.rollback()
        raise
    finally:
        conn.close()


async def transact(fn):
    return await asyncio.to_thread(transaction, fn)


async def persist(sql, params, patient_id, event_uuid, status):
    def write(c):
        row = c.execute('SELECT patient_id FROM fall_events WHERE event_uuid=?', (event_uuid,)).fetchone()
        if row and row['patient_id'] != patient_id:
            from fastapi import HTTPException
            raise HTTPException(404, 'Fall event not found.')
        c.execute(sql, params)
        actual = c.execute('SELECT status FROM fall_events WHERE event_uuid=?', (event_uuid,)).fetchone()['status']
        now = time.time()
        candidate = actual == 'candidate_check_in_pending'
        resolved = actual in ('canceled_false_alarm', 'suppressed_unworn_drop')
        due = now + settings.fall_check_in_sec if candidate else now
        c.execute('''INSERT INTO fall_jobs(event_uuid,patient_id,state,next_due,deadline)
          VALUES(?,?,?,?,?) ON CONFLICT(event_uuid) DO NOTHING''',
          (event_uuid, patient_id, 'resolved' if resolved else ('check_in' if candidate else 'pending'), due, due + settings.retry_window_sec))
        if resolved:
            c.execute("UPDATE fall_jobs SET state='resolved' WHERE event_uuid=? AND patient_id=?", (event_uuid,patient_id))
        elif not candidate:
            c.execute("UPDATE fall_jobs SET state='pending',next_due=?,deadline=? WHERE event_uuid=? AND state='check_in'", (now,now+settings.retry_window_sec,event_uuid))
        return actual
    return await transact(write)


async def begin(patient_id, event_uuid, role, phone, attempt_no, primary=False, expected_attempt_no=None):
    def claim(c):
        now = time.time()
        job = c.execute('SELECT * FROM fall_jobs WHERE event_uuid=? AND patient_id=?', (event_uuid,patient_id)).fetchone()
        if not job or job['state'] in ('resolved','exhausted') or job['lease_until'] > now or job['deadline'] <= now:
            return None
        if expected_attempt_no is not None and (job['attempt_no'] != expected_attempt_no or job['next_due'] > now):
            return None
        if primary:
            # Queue retries and stale recovery snapshots cannot restart initial dispatch.
            # Once an attempt exists, the durable retry schedule owns the next call.
            if job['attempt_no'] >= 0:
                return None
            changed=c.execute("UPDATE fall_events SET status='escalated_twilio' WHERE event_uuid=? AND patient_id=? AND status='confirmed_waiting_dispatch'",(event_uuid,patient_id)).rowcount
            if not changed: return None
        # Never overwrite a previous attempt, even one with an unknown external outcome.
        n = max(attempt_no, int(job['attempt_no'])+1)
        token = str(uuid.uuid4())
        c.execute("UPDATE fall_attempts SET state='delivery_unknown' WHERE event_uuid=? AND state='in_flight'",(event_uuid,))
        c.execute("UPDATE caregiver_alerts SET delivery_status='delivery_unknown' WHERE fall_event_uuid=? AND delivery_status='pending_dispatch'",(event_uuid,))
        c.execute('''INSERT INTO fall_attempts(attempt_id,event_uuid,patient_id,attempt_no,contact_role,to_phone,started_at,state)
          VALUES(?,?,?,?,?,?,?,'in_flight')''',(token,event_uuid,patient_id,n,role,phone,now))
        c.execute("UPDATE fall_jobs SET state='in_flight',lease_token=?,lease_until=?,attempt_no=? WHERE event_uuid=?",(token,now+settings.dispatch_lease_sec,n,event_uuid))
        return token
    return await transact(claim)


def queue_clears(c, event_uuid, patient_id):
    now=time.time()
    for row in c.execute('SELECT DISTINCT to_phone FROM fall_attempts WHERE event_uuid=? AND patient_id=? AND state!=?',(event_uuid,patient_id,'failed')).fetchall():
        c.execute('''INSERT INTO fall_clear_jobs(event_uuid,patient_id,to_phone,next_due) VALUES(?,?,?,?)
          ON CONFLICT(event_uuid,to_phone) DO NOTHING''',(event_uuid,patient_id,row['to_phone'],now))


async def finish(token, result):
    def commit(c):
        a=c.execute('SELECT * FROM fall_attempts WHERE attempt_id=?',(token,)).fetchone()
        if not a: return result
        sid=result.get('sms_sid') or a['sms_sid'] or ''; call=result.get('call_sid') or a['call_sid'] or ''
        normalized={**result,'sms_sid':sid,'call_sid':call}
        accepted=bool(sid or call)
        simulated=sid.startswith('SM_SIM_') or call.startswith('CA_SIM_')
        # A signed callback may already have acknowledged/recorded this attempt.
        c.execute('''UPDATE fall_attempts SET sms_sid=COALESCE(NULLIF(?,''),sms_sid),call_sid=COALESCE(NULLIF(?,''),call_sid),
          simulated=?,state=CASE WHEN acknowledged_at IS NOT NULL THEN 'acknowledged' ELSE ? END WHERE attempt_id=?''',
          (sid,call,int(simulated),'accepted' if accepted else ('failed' if result.get('delivery_status')=='unconfigured' else 'delivery_unknown'),token))
        job=c.execute('SELECT * FROM fall_jobs WHERE event_uuid=?',(a['event_uuid'],)).fetchone()
        if job['lease_token'] != token: return normalized  # stale worker cannot move the newer job
        resolved=job['state']=='resolved'
        state='resolved' if resolved else ('waiting_ack' if accepted else 'pending')
        delay=settings.secondary_escalation_delay_sec if a['attempt_no']==0 and accepted else settings.retry_interval_sec
        c.execute('UPDATE fall_jobs SET state=?,next_due=?,lease_until=0,lease_token=NULL WHERE event_uuid=?',(state,time.time()+delay,a['event_uuid']))
        if accepted:
            c.execute('''UPDATE fall_events SET caregiver_sms_sid=COALESCE(NULLIF(?,''),caregiver_sms_sid),
             caregiver_call_sid=COALESCE(NULLIF(?,''),caregiver_call_sid),status=CASE WHEN status='canceled_false_alarm' THEN status ELSE 'escalated_twilio' END WHERE event_uuid=? AND patient_id=?''',(sid,call,a['event_uuid'],a['patient_id']))
        elif not resolved:
            c.execute("UPDATE fall_events SET status='confirmed_waiting_dispatch' WHERE event_uuid=? AND patient_id=?",(a['event_uuid'],a['patient_id']))
        fall=c.execute('SELECT status FROM fall_events WHERE event_uuid=?',(a['event_uuid'],)).fetchone()
        if resolved and fall and fall['status']=='canceled_false_alarm': queue_clears(c,a['event_uuid'],a['patient_id'])
        return normalized
    return await transact(commit)


async def cancel(patient_id,event_uuid):
    def stop(c):
        owner=c.execute("SELECT patient_id FROM fall_events WHERE event_uuid=?",(event_uuid,)).fetchone()
        if owner and owner['patient_id'] != patient_id:
            from fastapi import HTTPException
            raise HTTPException(404,'Fall event not found.')
        c.execute("UPDATE fall_events SET status='canceled_false_alarm' WHERE event_uuid=? AND patient_id=?",(event_uuid,patient_id))
        c.execute("UPDATE fall_jobs SET state='resolved' WHERE event_uuid=? AND patient_id=?",(event_uuid,patient_id))
        c.execute("UPDATE caregiver_alerts SET delivery_status='canceled_by_user' WHERE fall_event_uuid=? AND patient_id=?",(event_uuid,patient_id))
        queue_clears(c,event_uuid,patient_id)
    await transact(stop)


async def due_jobs():
    def read(c):
        now=time.time()
        # A missing phone check-in result has a persisted, server-owned timeout.
        c.execute("UPDATE fall_events SET status='confirmed_waiting_dispatch' WHERE status='candidate_check_in_pending' AND event_uuid IN (SELECT event_uuid FROM fall_jobs WHERE state='check_in' AND next_due<=?)",(now,))
        c.execute("UPDATE fall_jobs SET state='pending' WHERE state='check_in' AND next_due<=?",(now,))
        expired=c.execute("SELECT event_uuid FROM fall_jobs WHERE state NOT IN ('resolved','exhausted') AND deadline<=?",(now,)).fetchall()
        for row in expired:
            c.execute("UPDATE fall_jobs SET state='exhausted' WHERE event_uuid=?",(row['event_uuid'],))
            c.execute("UPDATE caregiver_alerts SET delivery_status='exhausted_15m' WHERE fall_event_uuid=? AND delivery_status NOT IN ('acknowledged_by_caregiver','canceled_by_user')",(row['event_uuid'],))
        return [dict(r) for r in c.execute("SELECT * FROM fall_jobs WHERE state NOT IN ('resolved','exhausted','check_in') AND next_due<=? AND lease_until<=?",(now,now)).fetchall()]
    return await transact(read)


async def send_pending_clears(client):
    def claim(c):
        now=time.time(); token=str(uuid.uuid4())
        rows=c.execute("""SELECT j.* FROM fall_clear_jobs j JOIN fall_jobs f ON f.event_uuid=j.event_uuid
          WHERE j.state!='sent' AND j.next_due<=? AND j.lease_until<=? AND f.lease_until<=?""",(now,now,now)).fetchall()
        for r in rows:
            c.execute("UPDATE fall_clear_jobs SET state='leased',lease_token=?,lease_until=? WHERE event_uuid=? AND to_phone=?",(token,now+settings.dispatch_lease_sec,r['event_uuid'],r['to_phone']))
        return token,[dict(r) for r in rows]
    token,rows=await transact(claim); sent=0
    for r in rows:
        try: result=await asyncio.wait_for(client.send_all_clear_sms(r['to_phone'],r['event_uuid']),settings.dispatch_timeout_sec)
        except Exception: result={}
        sid=result.get('sms_sid') or ''
        def complete(c):
            c.execute("UPDATE fall_clear_jobs SET state=?,provider_sid=?,next_due=?,lease_until=0 WHERE event_uuid=? AND to_phone=? AND lease_token=?",('sent' if sid else 'pending',sid,time.time()+settings.retry_interval_sec,r['event_uuid'],r['to_phone'],token))
        await transact(complete)
        if sid:
            from datetime import datetime, timezone
            from app.clients.twilio_client import mask_phone
            from app.db import execute_write
            await execute_write("""INSERT INTO caregiver_alerts(patient_id,fall_event_uuid,timestamp_utc,contact_role,contact_phone_masked,channel,provider_sid,delivery_status,retry_count)
              VALUES(?,?,?,'notified_contact',?,'all_clear_sms',?,'canceled_by_user',0)""",
              (r['patient_id'],r['event_uuid'],datetime.now(timezone.utc).isoformat(),mask_phone(r['to_phone']),sid))
            sent+=1
    return sent
