import asyncio
import os
import sqlite3
from datetime import datetime, timedelta, timezone
from typing import Any, Dict, List, Optional, Tuple

from app.config import settings


class DatabaseEncryptionError(RuntimeError):
    """Raised when a configured key would otherwise leave the database readable."""

SCHEMA_SQL = """
PRAGMA journal_mode=WAL;
PRAGMA synchronous=NORMAL;
PRAGMA foreign_keys=ON;

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
    medication_state_label TEXT NOT NULL,
    minutes_since_last_dose INTEGER,
    voice_mean_dbfs REAL NOT NULL,
    voice_stability_db REAL NOT NULL,
    voice_score REAL NOT NULL,
    handwriting_opencv_decay_pct REAL NOT NULL,
    handwriting_sam_decay_pct REAL,
    handwriting_score REAL NOT NULL,
    walk_cadence_spm REAL NOT NULL,
    walk_mean_fi REAL NOT NULL,
    walk_fog_count INTEGER NOT NULL,
    gait_score REAL NOT NULL,
    composite_motor_score REAL NOT NULL,
    clinical_summary TEXT NOT NULL
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
    for suffix in ("", "-wal", "-shm"):
        candidate = f"{path}{suffix}"
        if os.path.exists(candidate):
            os.remove(candidate)
    raise DatabaseEncryptionError(
        f"{path} is a plaintext SQLite file while SQLITE_ENCRYPTION_KEY is set."
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


def init_db_sync(db_path: Optional[str] = None) -> None:
    conn = _connect_sync(db_path)
    try:
        conn.executescript(SCHEMA_SQL)
        conn.commit()
    finally:
        conn.close()
    if settings.sqlite_encryption_key:
        _refuse_plaintext_database(db_path or settings.sqlite_db_path)


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
            "DELETE FROM fall_events WHERE status = 'canceled_false_alarm' AND timestamp_utc < ?",
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
) -> Dict[str, int]:
    """
    Explicit patient-initiated wipe (DELETE /api/v1/patient/data).
    Deletes all rows for the bound patient_id across all 8 tables, including incident audit rows.
    """
    conn = _connect_sync(db_path)
    deleted: Dict[str, int] = {}
    try:
        # Delete child caregiver_alerts first due to foreign key
        tables_ordered = [
            "caregiver_alerts",
            "fall_events",
            "fog_events",
            "medication_logs",
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
        conn.commit()
        return deleted
    finally:
        conn.close()


async def wipe_patient_data(
    patient_id: str,
    db_path: Optional[str] = None,
) -> Dict[str, int]:
    return await asyncio.to_thread(wipe_patient_data_sync, patient_id, db_path)
