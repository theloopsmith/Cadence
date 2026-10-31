import asyncio
import os
import sqlite3
import uuid
from datetime import datetime, timedelta, timezone
from typing import Any, Dict, List, Optional, Tuple

from app.config import settings


class DatabaseEncryptionError(RuntimeError):
    """Raised when a configured key would otherwise leave the database readable."""


class DataGenerationChanged(Exception):
    def __init__(self, generation):
        self.generation = generation
        super().__init__('Server data was erased. Old pending changes cannot be restored.')


def data_generation_sync(patient_id, conn=None):
    owned = conn is None
    conn = conn or _connect_sync()
    try:
        return conn.execute('SELECT COUNT(*) FROM patient_wipes WHERE patient_id=?', (patient_id,)).fetchone()[0]
    finally:
        if owned: conn.close()


def require_data_generation(conn, patient_id, generation):
    current = data_generation_sync(patient_id, conn)
    if generation != current:
        raise DataGenerationChanged(current)


def patient_transaction_sync(patient_id, generation, operation):
    conn = _connect_sync()
    try:
        conn.execute('PRAGMA synchronous=FULL')
        conn.execute('BEGIN IMMEDIATE')
        require_data_generation(conn, patient_id, generation)
        result = operation(conn)
        conn.commit()
        return result
    except BaseException:
        conn.rollback()
        raise
    finally:
        conn.close()


async def execute_patient_write(auth, query, params=()):
    return await asyncio.to_thread(patient_transaction_sync, auth.patient_id, auth.data_generation,
                                  lambda conn: conn.execute(query, params).rowcount)


async def record_dose_retraction(auth, payload):
    def retract(conn):
        prior = conn.execute('SELECT patient_id,retracted_event_uuid FROM medication_retractions WHERE event_uuid=?',
                             (payload.event_uuid,)).fetchone()
        if prior and prior['patient_id'] != auth.patient_id:
            from fastapi import HTTPException
            raise HTTPException(404, 'Undo record not found.')
        if prior and prior['retracted_event_uuid'] != payload.retracted_event_uuid:
            from fastapi import HTTPException
            raise HTTPException(409, 'This undo identifier already refers to a different dose.')
        target = conn.execute('SELECT patient_id FROM medication_logs WHERE event_uuid=?', (payload.retracted_event_uuid,)).fetchone()
        if target and target['patient_id'] != auth.patient_id:
            from fastapi import HTTPException
            raise HTTPException(404, 'Dose not found.')
        conn.execute('''INSERT INTO medication_retractions(patient_id,event_uuid,retracted_event_uuid,timestamp_utc,reason)
            VALUES(?,?,?,?,?) ON CONFLICT(event_uuid) DO NOTHING''',
            (auth.patient_id,payload.event_uuid,payload.retracted_event_uuid,payload.timestamp_utc,payload.reason or 'user_undo'))
        conn.execute('DELETE FROM medication_logs WHERE patient_id=? AND event_uuid=?',
                     (auth.patient_id,payload.retracted_event_uuid))
    await asyncio.to_thread(patient_transaction_sync, auth.patient_id, auth.data_generation, retract)

SCHEMA_SQL = """
PRAGMA journal_mode=WAL;
PRAGMA synchronous=NORMAL;
PRAGMA foreign_keys=ON;

CREATE TABLE IF NOT EXISTS server_identity (
    singleton INTEGER PRIMARY KEY CHECK(singleton=1), server_id TEXT NOT NULL
);

-- 1. Freezing of Gait (FoG) Events
CREATE TABLE IF NOT EXISTS fog_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    patient_id TEXT NOT NULL DEFAULT 'default_patient',
    event_uuid TEXT UNIQUE NOT NULL,
    timestamp_utc TEXT NOT NULL,
    duration_sec REAL NOT NULL,
    peak_freeze_index REAL NOT NULL,
    locomotor_band_power REAL NOT NULL,
    freeze_band_power REAL NOT NULL,
    sampled_hz REAL NOT NULL DEFAULT 50.0,
    arming_mode TEXT NOT NULL,
    speech_active_modifier INTEGER NOT NULL DEFAULT 0,
    cue_bpm INTEGER NOT NULL DEFAULT 100,
    recovery_latency_sec REAL
);
CREATE INDEX IF NOT EXISTS idx_fog_events_patient_ts ON fog_events(patient_id, timestamp_utc);

-- 2. Fall Events
CREATE TABLE IF NOT EXISTS fall_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    patient_id TEXT NOT NULL DEFAULT 'default_patient',
    event_uuid TEXT UNIQUE NOT NULL,
    timestamp_utc TEXT NOT NULL,
    peak_impact_g REAL NOT NULL,
    peak_jerk_gs REAL NOT NULL,
    post_impact_tilt_deg REAL NOT NULL,
    pre_impact_wear_rms_g REAL NOT NULL,
    pre_impact_resp_power REAL NOT NULL DEFAULT 0.0,
    worn_pre_impact INTEGER NOT NULL DEFAULT 1,
    latitude REAL,
    longitude REAL,
    horizontal_accuracy_m REAL,
    status TEXT NOT NULL,
    cancel_transcript TEXT,
    caregiver_sms_sid TEXT,
    caregiver_call_sid TEXT,
    local_siren_activated INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_fall_events_patient_ts ON fall_events(patient_id, timestamp_utc);

-- 3. Caregiver Escalation & Retry Audit Log (Exempt from 30d auto-purge)
CREATE TABLE IF NOT EXISTS caregiver_alerts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    patient_id TEXT NOT NULL DEFAULT 'default_patient',
    fall_event_uuid TEXT NOT NULL,
    timestamp_utc TEXT NOT NULL,
    contact_role TEXT NOT NULL,
    contact_phone_masked TEXT NOT NULL,
    channel TEXT NOT NULL,
    provider_sid TEXT,
    delivery_status TEXT NOT NULL,
    acknowledged_at_utc TEXT,
    retry_count INTEGER NOT NULL DEFAULT 0,
    FOREIGN KEY(fall_event_uuid) REFERENCES fall_events(event_uuid)
);
CREATE INDEX IF NOT EXISTS idx_caregiver_alerts_patient_ts ON caregiver_alerts(patient_id, timestamp_utc);

-- 4. Medication & Plate-Normalized Meal Protein Logs
CREATE TABLE IF NOT EXISTS medication_logs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    patient_id TEXT NOT NULL DEFAULT 'default_patient',
    event_uuid TEXT UNIQUE NOT NULL,
    timestamp_utc TEXT NOT NULL,
    event_type TEXT NOT NULL,
    medication_name TEXT,
    scheduled_time_utc TEXT,
    detected_foods_json TEXT,
    plate_detected INTEGER NOT NULL DEFAULT 0,
    plate_area_ratio REAL,
    estimated_protein_grams REAL,
    conflict_detected INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_medication_logs_patient_ts ON medication_logs(patient_id, timestamp_utc);

-- 5. Hallucination Reality Check Metadata Logs (Zero Raw Images Stored)
CREATE TABLE IF NOT EXISTS reality_checks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    patient_id TEXT NOT NULL DEFAULT 'default_patient',
    event_uuid TEXT UNIQUE NOT NULL,
    timestamp_utc TEXT NOT NULL,
    user_query TEXT NOT NULL,
    sam_verified INTEGER NOT NULL DEFAULT 1,
    sam_masks_json TEXT NOT NULL,
    living_subject_present INTEGER NOT NULL,
    chosen_inanimate_label TEXT,
    template_id TEXT NOT NULL,
    spoken_response TEXT NOT NULL,
    latency_ms INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_reality_checks_patient_ts ON reality_checks(patient_id, timestamp_utc);

-- 6. Handwriting Micrographia Logs (Both OpenCV & SAM 3.1 Decay Stored)
CREATE TABLE IF NOT EXISTS handwriting_logs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    patient_id TEXT NOT NULL DEFAULT 'default_patient',
    event_uuid TEXT UNIQUE NOT NULL,
    timestamp_utc TEXT NOT NULL,
    letter_boxes_json TEXT NOT NULL,
    initial_stroke_height_px REAL NOT NULL,
    final_stroke_height_px REAL NOT NULL,
    opencv_cc_decay_pct REAL NOT NULL,
    sam_3_1_decay_pct REAL,
    micrographia_detected INTEGER NOT NULL,
    deskew_angle_deg REAL NOT NULL DEFAULT 0.0,
    source_context TEXT NOT NULL DEFAULT 'ambient'
);
CREATE INDEX IF NOT EXISTS idx_handwriting_logs_patient_ts ON handwriting_logs(patient_id, timestamp_utc);

-- 7. Guided Home Motor Exams
CREATE TABLE IF NOT EXISTS motor_exams (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    patient_id TEXT NOT NULL DEFAULT 'default_patient',
    exam_uuid TEXT UNIQUE NOT NULL,
    timestamp_utc TEXT NOT NULL,
    medication_state_label TEXT,
    minutes_since_last_dose INTEGER,
    voice_mean_dbfs REAL,
    voice_stability_db REAL,
    voice_score REAL,
    handwriting_opencv_decay_pct REAL,
    handwriting_sam_decay_pct REAL,
    handwriting_score REAL,
    walk_cadence_spm REAL,
    walk_mean_fi REAL,
    walk_fog_count INTEGER,
    gait_score REAL,
    composite_motor_score REAL,
    clinical_summary TEXT NOT NULL,
    voice_status TEXT NOT NULL DEFAULT 'legacy_unverified',
    handwriting_status TEXT NOT NULL DEFAULT 'legacy_unverified',
    walk_status TEXT NOT NULL DEFAULT 'legacy_unverified',
    measurement_source TEXT NOT NULL DEFAULT 'legacy_unverified'
);
CREATE INDEX IF NOT EXISTS idx_motor_exams_patient_ts ON motor_exams(patient_id, timestamp_utc);

-- 9. Accounts (scrypt password hashes only; never the password)
CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    username TEXT UNIQUE NOT NULL,
    password_hash TEXT NOT NULL,
    role TEXT NOT NULL,
    patient_id TEXT NOT NULL DEFAULT 'default_patient',
    created_at_utc TEXT NOT NULL
);

-- Reservations count as failed attempts until successful verification. This
-- budget is shared by every worker using the same database and survives restart.
CREATE TABLE IF NOT EXISTS login_attempts (
    username_hash TEXT PRIMARY KEY,
    attempts INTEGER NOT NULL,
    locked_until REAL NOT NULL,
    expires_at REAL NOT NULL,
    revision TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_login_attempts_expiry ON login_attempts(expires_at);

-- 8. Voice Hypophonia Logs
CREATE TABLE IF NOT EXISTS voice_logs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    patient_id TEXT NOT NULL DEFAULT 'default_patient',
    event_uuid TEXT UNIQUE NOT NULL,
    timestamp_utc TEXT NOT NULL,
    window_mean_dbfs REAL NOT NULL,
    baseline_dbfs REAL NOT NULL,
    nudge_triggered INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_voice_logs_patient_ts ON voice_logs(patient_id, timestamp_utc);

-- 10. Medication Retractions (Dose Undo Idempotent Ledger)
CREATE TABLE IF NOT EXISTS medication_retractions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    patient_id TEXT NOT NULL DEFAULT 'default_patient',
    event_uuid TEXT UNIQUE NOT NULL,
    retracted_event_uuid TEXT NOT NULL,
    timestamp_utc TEXT NOT NULL,
    reason TEXT NOT NULL DEFAULT 'user_undo'
);
CREATE INDEX IF NOT EXISTS idx_medication_retractions_patient_target ON medication_retractions(patient_id, retracted_event_uuid);

-- 11. Patient Wipe History (Server-Wipe & Queue Coordination)
CREATE TABLE IF NOT EXISTS patient_wipes (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    patient_id TEXT NOT NULL,
    wiped_at_utc TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_patient_wipes_patient_ts ON patient_wipes(patient_id, wiped_at_utc);
"""


def _refuse_plaintext_database(path: str) -> None:
    """A keyed database whose bytes start with the SQLite header is not encrypted."""
    if not path or path == ":memory:" or not os.path.exists(path):
        return
    if os.path.getsize(path) == 0:
        return
    with open(path, "rb") as handle:
        header = handle.read(16)
    if not header.startswith(b"SQLite format 3"):
        return
    # Refuse, never delete: this file may hold the fall ledger. The operator
    # decides whether to migrate it or point the key at a new path.
    raise DatabaseEncryptionError(
        f"{path} is a plaintext SQLite file while SQLITE_ENCRYPTION_KEY is set. "
        "Move it aside or choose a new SQLITE_DB_PATH; Cadence will not delete data."
    )


def _connect_sync(db_path: Optional[str] = None) -> sqlite3.Connection:
    """Opens a synchronous SQLite connection, or SQLCipher when a key is set."""
    target_path = db_path or settings.sqlite_db_path
    if settings.sqlite_encryption_key:
        _refuse_plaintext_database(target_path)
        try:
            import sqlcipher3 as sqlcipher  # type: ignore
        except ImportError as exc:
            raise DatabaseEncryptionError(
                "SQLITE_ENCRYPTION_KEY is set but sqlcipher3 is not installed. "
                "Refusing to open a plaintext database."
            ) from exc
        conn = sqlcipher.connect(target_path, check_same_thread=False)
        escaped_key = settings.sqlite_encryption_key.replace("'", "''")
        conn.execute(f"PRAGMA key = '{escaped_key}';")
        conn.row_factory = sqlcipher.Row
        return conn
    conn = sqlite3.connect(target_path, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys=ON;")
    return conn


def _migrate_exam_validity(conn):
    """Rebuild legacy NOT NULL columns atomically; preserve old values for audit.

    Legacy rows get unknown validity. API/report projection withholds their
    numbers rather than guessing which old defaults were real observations.
    """
    conn.execute("CREATE TABLE IF NOT EXISTS schema_migrations (name TEXT PRIMARY KEY)")
    conn.commit()
    conn.execute('BEGIN IMMEDIATE')
    if conn.execute("SELECT 1 FROM schema_migrations WHERE name='motor_exam_validity_v1'").fetchone():
        return
    columns = [r['name'] for r in conn.execute('PRAGMA table_info(motor_exams)')]
    if 'voice_status' not in columns:
        start = SCHEMA_SQL.index('CREATE TABLE IF NOT EXISTS motor_exams (')
        end = SCHEMA_SQL.index(');', start) + 2
        conn.execute(SCHEMA_SQL[start:end].replace('IF NOT EXISTS motor_exams', 'motor_exams_validity_new'))
        names = ','.join(columns)
        conn.execute(f'INSERT INTO motor_exams_validity_new ({names}) SELECT {names} FROM motor_exams')
        conn.execute('DROP TABLE motor_exams')
        conn.execute('ALTER TABLE motor_exams_validity_new RENAME TO motor_exams')
        conn.execute('CREATE INDEX idx_motor_exams_patient_ts ON motor_exams(patient_id,timestamp_utc)')
    conn.execute("INSERT INTO schema_migrations(name) VALUES('motor_exam_validity_v1')")


def init_db_sync(db_path: Optional[str] = None) -> None:
    target = db_path or settings.sqlite_db_path
    existed_before = bool(target) and target != ":memory:" and os.path.exists(target)
    conn = _connect_sync(db_path)
    try:
        from app.services.fall_durability import SCHEMA as FALL_OUTBOX_SCHEMA
        conn.executescript(SCHEMA_SQL + FALL_OUTBOX_SCHEMA)
        conn.execute('INSERT OR IGNORE INTO server_identity(singleton,server_id) VALUES(1,?)', (str(uuid.uuid4()),))
        _migrate_exam_validity(conn)
        conn.commit()
    finally:
        conn.close()
    if settings.sqlite_encryption_key:
        try:
            _refuse_plaintext_database(target)
        except DatabaseEncryptionError:
            if not existed_before:
                # Cadence created this file seconds ago through a module that did
                # not encrypt; it holds only an empty schema. Pre-existing files
                # are never removed.
                for suffix in ("", "-wal", "-shm"):
                    candidate = f"{target}{suffix}"
                    if os.path.exists(candidate):
                        os.remove(candidate)
            raise


async def init_db(db_path: Optional[str] = None) -> None:
    await asyncio.to_thread(init_db_sync, db_path)


def execute_write_sync(
    query: str,
    params: Tuple[Any, ...] = (),
    db_path: Optional[str] = None,
) -> int:
    """
    Synchronous DB commit before returning HTTP 200 OK or calling external APIs.
    Returns the number of rows the statement changed.
    """
    conn = _connect_sync(db_path)
    try:
        cur = conn.execute(query, params)
        conn.commit()
        return cur.rowcount
    finally:
        conn.close()


async def execute_write(
    query: str,
    params: Tuple[Any, ...] = (),
    db_path: Optional[str] = None,
) -> int:
    return await asyncio.to_thread(execute_write_sync, query, params, db_path)


def claim_caregiver_alert_sync(
    patient_id: str,
    fall_event_uuid: str,
    timestamp_utc: str,
    contact_role: str,
    contact_phone_masked: str,
    channel: str,
    retry_count: int,
    db_path: Optional[str] = None,
) -> int:
    """
    Inserts one escalation attempt, or returns 0 if that attempt already exists.

    The status webhook and the retry loop both try the same secondary dial.
    BEGIN IMMEDIATE serializes them so only one call is placed.
    """
    conn = _connect_sync(db_path)
    try:
        conn.execute("BEGIN IMMEDIATE")
        existing = conn.execute(
            """
            SELECT id FROM caregiver_alerts
            WHERE fall_event_uuid = ? AND contact_role = ?
              AND channel = ? AND retry_count = ?
            """,
            (fall_event_uuid, contact_role, channel, retry_count),
        ).fetchone()
        if existing is not None:
            conn.rollback()
            return 0
        cur = conn.execute(
            """
            INSERT INTO caregiver_alerts (
                patient_id, fall_event_uuid, timestamp_utc, contact_role,
                contact_phone_masked, channel, provider_sid, delivery_status, retry_count
            ) VALUES (?, ?, ?, ?, ?, ?, '', 'pending_dispatch', ?)
            """,
            (
                patient_id,
                fall_event_uuid,
                timestamp_utc,
                contact_role,
                contact_phone_masked,
                channel,
                retry_count,
            ),
        )
        conn.commit()
        return int(cur.lastrowid or 0)
    finally:
        conn.close()


async def claim_caregiver_alert(
    patient_id: str,
    fall_event_uuid: str,
    timestamp_utc: str,
    contact_role: str,
    contact_phone_masked: str,
    channel: str,
    retry_count: int,
    db_path: Optional[str] = None,
) -> int:
    return await asyncio.to_thread(
        claim_caregiver_alert_sync,
        patient_id,
        fall_event_uuid,
        timestamp_utc,
        contact_role,
        contact_phone_masked,
        channel,
        retry_count,
        db_path,
    )


def fetch_all_sync(
    query: str,
    params: Tuple[Any, ...] = (),
    db_path: Optional[str] = None,
) -> List[Dict[str, Any]]:
    conn = _connect_sync(db_path)
    try:
        cur = conn.execute(query, params)
        rows = cur.fetchall()
        return [dict(r) for r in rows]
    finally:
        conn.close()


async def fetch_all(
    query: str,
    params: Tuple[Any, ...] = (),
    db_path: Optional[str] = None,
) -> List[Dict[str, Any]]:
    return await asyncio.to_thread(fetch_all_sync, query, params, db_path)


def fetch_one_sync(
    query: str,
    params: Tuple[Any, ...] = (),
    db_path: Optional[str] = None,
) -> Optional[Dict[str, Any]]:
    conn = _connect_sync(db_path)
    try:
        cur = conn.execute(query, params)
        row = cur.fetchone()
        return dict(row) if row is not None else None
    finally:
        conn.close()


async def fetch_one(
    query: str,
    params: Tuple[Any, ...] = (),
    db_path: Optional[str] = None,
) -> Optional[Dict[str, Any]]:
    return await asyncio.to_thread(fetch_one_sync, query, params, db_path)


def purge_expired_telemetry_sync(db_path: Optional[str] = None) -> Dict[str, int]:
    """
    Purges routine telemetry older than RETENTION_DAYS (default 30d).
    Confirmed fall_events (status != 'canceled_false_alarm') and caregiver_alerts
    audit rows are EXEMPT from 30d purging (kept for RETENTION_INCIDENT_DAYS=365).
    """
    cutoff_routine = (
        datetime.now(timezone.utc) - timedelta(days=settings.retention_days)
    ).isoformat()
    cutoff_incident = (
        datetime.now(timezone.utc) - timedelta(days=settings.retention_incident_days)
    ).isoformat()

    conn = _connect_sync(db_path)
    purged: Dict[str, int] = {}
    try:
        routine_tables = [
            "fog_events",
            "medication_logs",
            "reality_checks",
            "handwriting_logs",
            "motor_exams",
            "voice_logs",
        ]
        for table in routine_tables:
            cur = conn.execute(
                f"DELETE FROM {table} WHERE timestamp_utc < ?", (cutoff_routine,)
            )
            purged[table] = cur.rowcount

        # Canceled false-alarm falls expire at 30d; confirmed falls & caregiver_alerts at 365d
        cur_false_falls = conn.execute(
            "DELETE FROM fall_events WHERE status = 'canceled_false_alarm' AND timestamp_utc < ? AND NOT EXISTS (SELECT 1 FROM caregiver_alerts a WHERE a.fall_event_uuid=fall_events.event_uuid) AND NOT EXISTS (SELECT 1 FROM fall_jobs j WHERE j.event_uuid=fall_events.event_uuid)",
            (cutoff_routine,),
        )
        purged["fall_events_false_alarm"] = cur_false_falls.rowcount

        cur_alerts = conn.execute(
            "DELETE FROM caregiver_alerts WHERE timestamp_utc < ?",
            (cutoff_incident,),
        )
        purged["caregiver_alerts_expired"] = cur_alerts.rowcount

        conn.commit()
        return purged
    finally:
        conn.close()


async def purge_expired_telemetry(db_path: Optional[str] = None) -> Dict[str, int]:
    return await asyncio.to_thread(purge_expired_telemetry_sync, db_path)


def wipe_patient_data_sync(
    patient_id: str,
    db_path: Optional[str] = None,
) -> Dict[str, Any]:
    """
    Explicit patient-initiated wipe (DELETE /api/v1/patient/data).
    Deletes all rows for the bound patient_id across all tables, including incident audit rows,
    and logs the wipe timestamp in patient_wipes for offline upload coordination.
    """
    conn = _connect_sync(db_path)
    deleted: Dict[str, Any] = {}
    try:
        conn.execute('PRAGMA synchronous=FULL')
        conn.execute('BEGIN IMMEDIATE')
        # Delete child caregiver_alerts first due to foreign key
        tables_ordered = [
            "fall_clear_jobs", "fall_attempts", "fall_jobs",
            "caregiver_alerts",
            "fall_events",
            "fog_events",
            "medication_logs",
            "medication_retractions",
            "reality_checks",
            "handwriting_logs",
            "motor_exams",
            "voice_logs",
        ]
        for table in tables_ordered:
            cur = conn.execute(
                f"DELETE FROM {table} WHERE patient_id = ?", (patient_id,)
            )
            deleted[table] = cur.rowcount

        wiped_at_utc = datetime.now(timezone.utc).isoformat()
        conn.execute(
            "INSERT INTO patient_wipes (patient_id, wiped_at_utc) VALUES (?, ?)",
            (patient_id, wiped_at_utc),
        )
        deleted['data_generation'] = data_generation_sync(patient_id, conn)
        conn.commit()
        deleted["wiped_at_utc"] = wiped_at_utc
        return deleted
    finally:
        conn.close()


async def wipe_patient_data(
    patient_id: str,
    db_path: Optional[str] = None,
) -> Dict[str, int]:
    return await asyncio.to_thread(wipe_patient_data_sync, patient_id, db_path)
