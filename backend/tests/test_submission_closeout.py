"""Submission hardening: repeatable upgrades, provenance and temporary access."""
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
from datetime import datetime, timedelta, timezone
import jwt
import pytest
from app import auth
from app.config import settings
from app.db import init_db_sync, fetch_one_sync
from app.services.exam_validity import measured_exam


def test_backend_dotenv_is_loaded_when_started_from_repository_root(tmp_path, monkeypatch):
    backend = tmp_path / 'backend'
    (backend/'app').mkdir(parents=True)
    shutil.copy(Path(__file__).resolve().parents[1]/'app/config.py', backend/'app/config.py')
    (backend/'.env').write_text('JWT_DEVICE_TTL_DAYS=19\n')
    env = {**os.environ, 'PYTHONPATH': str(backend)}
    env.pop('JWT_DEVICE_TTL_DAYS', None)
    result = subprocess.run([sys.executable, '-c', 'from app.config import settings; print(settings.jwt_device_ttl_days)'],
                            cwd=tmp_path, env=env, text=True, capture_output=True, check=True)
    assert result.stdout.strip() == '19'


def test_retired_column_upgrade_preserves_observations_ids_indexes_and_is_repeatable(tmp_path):
    db = tmp_path/'legacy.db'
    init_db_sync(str(db))
    with sqlite3.connect(db) as conn:
        conn.execute('ALTER TABLE medication_logs ADD COLUMN estimated_protein_grams REAL')
        conn.execute('ALTER TABLE medication_logs ADD COLUMN conflict_detected INTEGER')
        conn.execute("INSERT INTO medication_logs(id,patient_id,event_uuid,timestamp_utc,event_type,estimated_protein_grams,conflict_detected) VALUES(8,'p','meal-proof','2026-01-01','meal_logged',30,1)")
        conn.execute('ALTER TABLE motor_exams ADD COLUMN composite_motor_score REAL')
        conn.execute("INSERT INTO motor_exams(id,patient_id,exam_uuid,timestamp_utc,voice_mean_dbfs,voice_status,measurement_source,clinical_summary,composite_motor_score) VALUES(9,'p','exam-proof','2026-01-01',-25,'measured','device','legacy',90)")
        conn.execute('ALTER TABLE handwriting_logs ADD COLUMN micrographia_detected INTEGER')
        conn.execute("INSERT INTO handwriting_logs(id,patient_id,event_uuid,timestamp_utc,letter_boxes_json,initial_stroke_height_px,final_stroke_height_px,opencv_cc_decay_pct,micrographia_detected) VALUES(10,'p','writing-proof','2026-01-01','[]',40,30,-25,1)")
    for _ in range(2):
        init_db_sync(str(db))
        with sqlite3.connect(db) as conn:
            assert conn.execute("SELECT id,event_uuid FROM medication_logs").fetchone() == (8,'meal-proof')
            assert conn.execute("SELECT id,voice_mean_dbfs FROM motor_exams").fetchone() == (9,-25)
            assert conn.execute("SELECT id,opencv_cc_decay_pct FROM handwriting_logs").fetchone() == (10,-25)
            for table, removed in [('medication_logs','estimated_protein_grams'),('motor_exams','composite_motor_score'),('handwriting_logs','micrographia_detected')]:
                assert removed not in {r[1] for r in conn.execute(f'PRAGMA table_info({table})')}
                assert conn.execute("SELECT 1 FROM sqlite_master WHERE name=?",('idx_'+table+'_patient_ts',)).fetchone()
            assert conn.execute('PRAGMA foreign_key_check').fetchall() == []


def test_simulated_status_cannot_be_misread_as_live_measurement():
    for source, expected in [('simulated','simulated'),('device','measured'),('legacy_unverified','legacy_unverified')]:
        row=measured_exam(dict(measurement_source=source,voice_status='measured',handwriting_status='skipped',walk_status='unavailable',voice_mean_dbfs=-25))
        assert row['voice_status'] == row['task_evidence']['voice']['status'] == expected
        assert row['task_evidence']['voice']['measurement_source'] == source
        assert measured_exam(row) == row


def test_judge_retirement_caps_new_tokens_and_rejects_existing_tokens(monkeypatch):
    monkeypatch.setattr(settings,'cadence_env','public_demo')
    monkeypatch.setattr(settings,'jwt_secret','x'*40)
    monkeypatch.setattr(settings,'demo_accounts_expire_at_utc',datetime.now(timezone.utc)+timedelta(minutes=5))
    auth.create_user_sync('demo-reviewer','fixture password long enough','clinician_reader',settings.cadence_default_patient_id)
    issued=auth.authenticate_sync('demo-reviewer','fixture password long enough')
    claims=jwt.decode(issued.access_token,settings.jwt_secret,algorithms=['HS256'])
    assert claims['exp'] <= int(settings.demo_accounts_expire_at_utc.timestamp())
    ordinary=auth.issue_token('ordinary-account','device_writer',settings.cadence_default_patient_id)
    monkeypatch.setattr(settings,'demo_accounts_expire_at_utc',datetime.now(timezone.utc)-timedelta(seconds=1))
    assert auth.decode_token(issued.access_token) is None
    assert auth.decode_token(ordinary) is not None
    with pytest.raises(auth.AuthError,match='expired'):
        auth.authenticate_sync('demo-reviewer','fixture password long enough')


def test_public_demo_retires_writer_login_and_existing_token(monkeypatch):
    monkeypatch.setattr(settings, "cadence_env", "development")
    token = auth.issue_token("demo-wearer", "device_writer", settings.cadence_default_patient_id)
    assert auth.decode_token(token) is not None
    monkeypatch.setattr(settings, "cadence_env", "public_demo")
    assert auth.decode_token(token) is None
    with pytest.raises(auth.AuthError, match="live judge tiles"):
        auth.authenticate_sync("demo-wearer", "old public password")
