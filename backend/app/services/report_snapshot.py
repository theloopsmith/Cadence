import asyncio
from datetime import datetime, timedelta, timezone
from app.db import _connect_sync
from app.services.delivery_evidence import delivery_evidence
from app.services.dose_clock import parse_utc

TABLES = {
    'fog_events': 'fog_events', 'fall_events': 'fall_events', 'medication_logs': 'medication_logs',
    'reality_checks': 'reality_checks', 'handwriting_logs': 'handwriting_logs',
    'voice_logs': 'voice_logs', 'motor_exams': 'motor_exams',
}

def snapshot_sync(patient_id, end=None):
    conn = _connect_sync()
    try:
        conn.execute('BEGIN')
        conn.execute('SELECT 1 FROM fall_events LIMIT 1').fetchone()  # establish one read snapshot
        end = (end or datetime.now(timezone.utc)).astimezone(timezone.utc)
        start = end-timedelta(hours=24)
        # SQLite Julian dates have millisecond precision. Widen SQL bounds and
        # enforce the exact UTC half-open interval in Python, including microseconds.
        params = (patient_id, (start-timedelta(seconds=1)).isoformat(), (end+timedelta(seconds=1)).isoformat())
        predicate = 'patient_id=? AND julianday(timestamp_utc)>=julianday(?) AND julianday(timestamp_utc)<julianday(?)'
        retracted_uuids = {
            r[0]
            for r in conn.execute(
                "SELECT retracted_event_uuid FROM medication_retractions WHERE patient_id=?",
                (patient_id,),
            )
        }
        def rows_for(table):
            rows = []
            for raw in conn.execute(f'SELECT * FROM {table} WHERE {predicate}',params):
                row = dict(raw)
                if table == 'medication_logs' and row.get('event_uuid') in retracted_uuids:
                    continue
                try: at = parse_utc(row['timestamp_utc'])
                except (ValueError,TypeError): continue
                if start <= at < end:
                    row['timestamp_utc'] = at.isoformat()
                    rows.append(row)
            return sorted(rows,key=lambda r:(r['timestamp_utc'],r['id']),reverse=True)
        result = {name: rows_for(table) for name,table in TABLES.items()}
        attempts = [dict(r) for r in conn.execute(f'''SELECT a.* FROM fall_attempts a JOIN fall_events f ON f.event_uuid=a.event_uuid AND f.patient_id=a.patient_id
            WHERE f.{predicate.replace('timestamp_utc','f.timestamp_utc')}''',params)]
        # Prefix the owner separately above; all identifiers are fixed constants.
        jobs = {r['event_uuid']:dict(r) for r in conn.execute('SELECT * FROM fall_jobs WHERE patient_id=?',(patient_id,))}
        for fall in result['fall_events']:
            fall.update(delivery_evidence(fall,[a for a in attempts if a['event_uuid']==fall['event_uuid']], jobs.get(fall['event_uuid'])))
        result['start'] = start; result['end'] = end
        return result
    finally:
        conn.close()

async def report_snapshot(patient_id):
    return await asyncio.to_thread(snapshot_sync,patient_id)
