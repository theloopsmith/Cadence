import sqlite3
import pytest
from fastapi.testclient import TestClient
from app.config import settings
from app.db import init_db_sync, fetch_one_sync
from app.main import app

HEADERS = {'Authorization': 'Bearer cadence-dev-device-writer-token-2026'}

@pytest.fixture
def client(monkeypatch, tmp_path):
    monkeypatch.setattr(settings, 'sqlite_db_path', str(tmp_path/'validity.db'))
    monkeypatch.setattr(settings, 'enable_research_metrics', False)
    init_db_sync()
    with TestClient(app) as http: yield http

def complete_payload(uuid='validity-full'):
    return dict(exam_uuid=uuid, voice_status='measured', handwriting_status='measured', walk_status='measured',
        measurement_source='device', voice_mean_dbfs=-24, voice_stability_db=0, handwriting_opencv_decay_pct=0,
        walk_cadence_spm=0, walk_mean_fi=0, walk_fog_count=0)

def test_partial_check_nulls_stale_values_everywhere_and_never_scores(client, monkeypatch):
    monkeypatch.setattr(settings, 'enable_research_metrics', True)
    payload = complete_payload('partial-validity')
    payload.update(voice_status='unavailable', handwriting_status='skipped')
    response = client.post('/api/v1/exam/complete', headers=HEADERS, json=payload)
    assert response.status_code == 200
    row = response.json()
    assert row['voice_mean_dbfs'] is row['voice_stability_db'] is None
    assert row['handwriting_opencv_decay_pct'] is None
    assert row['walk_cadence_spm'] == row['walk_fog_count'] == 0
    assert row['composite_motor_score'] is row['medication_state_label'] is None
    assert row['complete'] is False
    assert 'voice was not measured' in row['clinical_summary']
    assert 'walking was 0 steps' in row['clinical_summary']
    stored = fetch_one_sync("SELECT * FROM motor_exams WHERE exam_uuid='partial-validity'")
    assert stored['voice_mean_dbfs'] is None
    history = client.get('/api/v1/exam/history', headers=HEADERS).json()['exams'][0]
    report = client.get('/api/v1/report/neurologist', headers=HEADERS).json()
    assert history['voice_mean_dbfs'] is report['motor_exams'][0]['voice_mean_dbfs'] is None
    assert report['summary_stats']['exam_on_vs_off_delta'] is None

def test_default_mode_does_not_execute_legacy_scoring(client, monkeypatch):
    def forbidden(*args, **kwargs): raise AssertionError('research scoring must not run')
    monkeypatch.setattr('app.main.score_home_motor_exam', forbidden)
    result = client.post('/api/v1/exam/complete', headers=HEADERS, json=complete_payload()).json()
    assert result['complete'] is True
    assert result['voice_stability_db'] == 0
    assert 'composite_motor_score' not in result
    assert fetch_one_sync('SELECT composite_motor_score FROM motor_exams')['composite_motor_score'] is None

@pytest.mark.parametrize('field', ['voice_mean_dbfs','voice_stability_db','handwriting_opencv_decay_pct','walk_cadence_spm','walk_mean_fi','walk_fog_count'])
def test_measured_tasks_must_supply_all_their_values(client, field):
    payload = complete_payload(); payload.pop(field)
    assert client.post('/api/v1/exam/complete', headers=HEADERS, json=payload).status_code == 422

def test_legacy_body_cannot_turn_defaults_into_measurements(client):
    payload = complete_payload('old-phone')
    for key in ('voice_status','handwriting_status','walk_status','measurement_source'): payload.pop(key)
    row = client.post('/api/v1/exam/complete', headers=HEADERS, json=payload).json()
    assert row['voice_status'] == 'legacy_unverified'
    assert row['voice_mean_dbfs'] is row['walk_cadence_spm'] is None
    assert row['complete'] is False

def test_replayed_body_returns_the_original_committed_result(client):
    payload = complete_payload('immutable-check')
    original = client.post('/api/v1/exam/complete', headers=HEADERS, json=payload).json()
    payload.update(voice_status='unavailable', voice_mean_dbfs=-99)
    replay = client.post('/api/v1/exam/complete', headers=HEADERS, json=payload).json()
    assert replay == original

@pytest.mark.parametrize('value', ['NaN', 'Infinity', '-Infinity'])
def test_nonfinite_measurements_are_rejected(client, value):
    payload = complete_payload(); payload['voice_mean_dbfs'] = value
    assert client.post('/api/v1/exam/complete', headers=HEADERS, json=payload).status_code == 422

def test_simulated_task_provenance_is_rejected_outside_demo(client, monkeypatch):
    monkeypatch.setattr(settings, 'demo_mode', False)
    payload = complete_payload(); payload['measurement_source'] = 'simulated'
    assert client.post('/api/v1/exam/complete', headers=HEADERS, json=payload).status_code == 400

def test_legacy_database_upgrade_preserves_raw_values_but_withholds_unverified_results(monkeypatch,tmp_path):
    path = str(tmp_path/'old-install.db')
    monkeypatch.setattr(settings,'sqlite_db_path',path)
    monkeypatch.setattr(settings,'enable_research_metrics',False)
    with sqlite3.connect(path) as conn:
        conn.execute('''CREATE TABLE motor_exams (
            id INTEGER PRIMARY KEY AUTOINCREMENT, patient_id TEXT NOT NULL, exam_uuid TEXT UNIQUE NOT NULL,
            timestamp_utc TEXT NOT NULL, medication_state_label TEXT NOT NULL, minutes_since_last_dose INTEGER,
            voice_mean_dbfs REAL NOT NULL, voice_stability_db REAL NOT NULL, voice_score REAL NOT NULL,
            handwriting_opencv_decay_pct REAL NOT NULL, handwriting_sam_decay_pct REAL, handwriting_score REAL NOT NULL,
            walk_cadence_spm REAL NOT NULL, walk_mean_fi REAL NOT NULL, walk_fog_count INTEGER NOT NULL,
            gait_score REAL NOT NULL, composite_motor_score REAL NOT NULL, clinical_summary TEXT NOT NULL)''')
        conn.execute("INSERT INTO motor_exams VALUES(7,'default_patient','old-check','2026-10-29T10:00:00+00:00','ON',30,-24,0,100,0,NULL,100,100,1,0,100,100,'Old score 100')")
    init_db_sync(); init_db_sync()  # upgrade and repeat startup must both be safe
    raw = fetch_one_sync("SELECT * FROM motor_exams WHERE exam_uuid='old-check'")
    assert raw['id']==7 and raw['voice_mean_dbfs']==-24 and raw['composite_motor_score']==100
    assert raw['voice_status']=='legacy_unverified'
    with TestClient(app) as http:
        row = http.get('/api/v1/exam/history',headers=HEADERS).json()['exams'][0]
        assert row['voice_mean_dbfs'] is row['walk_cadence_spm'] is None
        assert 'Old score' not in row['clinical_summary']
        # New nullable partial records must work on the upgraded install.
        response = http.post('/api/v1/exam/complete',headers=HEADERS,json=dict(exam_uuid='after-upgrade',voice_status='skipped',handwriting_status='unavailable',walk_status='skipped'))
        assert response.status_code==200
    assert fetch_one_sync("SELECT COUNT(*) AS n FROM schema_migrations WHERE name='motor_exam_validity_v1'")['n']==1
