import asyncio
import base64
import io
import threading
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone

# Ahead of the server clock but inside the accepted skew: proves the wipe ledger,
# not the timestamp, decides what may be restored.
SLIGHTLY_AHEAD = (datetime.now(timezone.utc) + timedelta(minutes=2)).strftime('%Y-%m-%dT%H:%M:%SZ')
from datetime import datetime, timedelta, timezone

from fastapi.testclient import TestClient
from PIL import Image

from app.config import settings
from app.db import fetch_one_sync, wipe_patient_data_sync, record_dose_retraction, patient_transaction_sync
from app.main import app
from app.models import DoseRetractionCreate


def headers(generation=0):
    return {'Authorization': f'Bearer {settings.cadence_device_token}', 'X-Cadence-Data-Generation': str(generation)}


def fog(uuid='generation-fog', timestamp=SLIGHTLY_AHEAD):
    return dict(event_uuid=uuid, timestamp_utc=timestamp, duration_sec=2, peak_freeze_index=3,
                locomotor_band_power=1, freeze_band_power=3)


def test_wipe_between_precheck_and_commit_cannot_restore_even_future_dated_data(monkeypatch):
    from app import main
    original = main.execute_patient_write

    async def erase_then_write(auth, query, params=()):
        await asyncio.to_thread(wipe_patient_data_sync, auth.patient_id)
        return await original(auth, query, params)

    monkeypatch.setattr(main, 'execute_patient_write', erase_then_write)
    response = TestClient(app).post('/api/v1/events/fog', headers=headers(), json=fog())
    assert response.status_code == 409
    assert response.json()['error'] == 'data_generation_changed'
    assert response.json()['data_generation'] == 1
    assert fetch_one_sync('SELECT COUNT(*) AS n FROM fog_events')['n'] == 0


def test_an_inflight_model_result_cannot_recreate_erased_observations(monkeypatch):
    from app import main

    async def model_reply(**kwargs):
        await asyncio.to_thread(wipe_patient_data_sync, settings.cadence_default_patient_id)
        return dict(sam_verified=True, verified_masks=[], living_subject_present=False,
                    chosen_inanimate_label=None, template_id='fixture', spoken_response='Fixture', latency_ms=1)

    monkeypatch.setattr(main, 'run_reality_check_pipeline', model_reply)
    image = io.BytesIO(); Image.new('RGB', (8, 8)).save(image, format='JPEG')
    response = TestClient(app).post('/api/v1/reality-check', headers=headers(), json={
        'event_uuid':'inflight-photo', 'timestamp_utc':SLIGHTLY_AHEAD, 'user_query':'Describe this',
        'image_base64':base64.b64encode(image.getvalue()).decode()})
    assert response.status_code == 409
    assert fetch_one_sync('SELECT COUNT(*) AS n FROM reality_checks')['n'] == 0


def test_old_fall_or_cancel_cannot_recreate_jobs_after_erase():
    client = TestClient(app)
    assert client.delete('/api/v1/patient/data', headers=headers()).json()['data_generation'] == 1
    fall = dict(event_uuid='old-fall', timestamp_utc=SLIGHTLY_AHEAD, peak_impact_g=3,
                peak_jerk_gs=6, post_impact_tilt_deg=70, status='candidate_check_in_pending')
    assert client.post('/api/v1/events/fall', headers=headers(), json=fall).status_code == 409
    assert client.post('/api/v1/events/fall/old-fall/cancel', headers=headers(), json={}).status_code == 409
    for table in ['fall_events','fall_jobs','fall_attempts','fall_clear_jobs']:
        assert fetch_one_sync(f'SELECT COUNT(*) AS n FROM {table}')['n'] == 0


def test_generation_is_authoritative_across_clock_skew_and_demo_seeding():
    client = TestClient(app)
    wipe = client.delete('/api/v1/patient/data', headers=headers()).json()
    assert wipe['data_generation'] == 1
    # A newly recorded action may have a badly skewed clock; its acknowledged
    # generation, rather than timestamp ordering, establishes its erase boundary.
    assert client.post('/api/v1/events/fog', headers=headers(1), json=fog('fresh-with-skew', '2000-01-01T00:00:00-08:00')).status_code == 200
    assert client.post('/api/v1/demo/seed', headers=headers(1)).status_code == 200
    assert client.get('/api/v1/device/connection', headers=headers()).json()['data_generation'] == 1
    assert client.post('/api/v1/events/fog', headers=headers(), json=fog('old-after-seed')).status_code == 409
    assert client.delete('/api/v1/patient/data', headers=headers()).json()['data_generation'] == 2
    assert client.get('/api/v1/report/neurologist', headers=headers()).json()['report_metadata']['data_generation'] == 2


def test_legacy_wipe_timestamp_check_compares_utc_instants_not_strings():
    client = TestClient(app)
    client.delete('/api/v1/patient/data', headers=headers())
    old = (datetime.now(timezone.utc)-timedelta(hours=1)).astimezone(timezone(timedelta(hours=9))).isoformat()
    response = client.post('/api/v1/events/fog', headers=headers(), json=fog(timestamp=old))
    assert response.json()['status'] == 'dropped_wiped'
    assert fetch_one_sync('SELECT COUNT(*) AS n FROM fog_events')['n'] == 0


def test_undo_cannot_be_replayed_to_delete_a_different_dose():
    client = TestClient(app)
    for uuid in ['dose-one','dose-two']:
        assert client.post('/api/v1/medication/dose', headers=headers(), json={'event_uuid':uuid}).status_code == 200
    undo = dict(event_uuid='one-undo', retracted_event_uuid='dose-one')
    assert client.post('/api/v1/medication/dose/retract', headers=headers(), json=undo).status_code == 200
    undo['retracted_event_uuid'] = 'dose-two'
    assert client.post('/api/v1/medication/dose/retract', headers=headers(), json=undo).status_code == 409
    assert fetch_one_sync("SELECT COUNT(*) AS n FROM medication_logs WHERE event_uuid='dose-two'")['n'] == 1


def test_undo_committed_after_dose_precheck_still_prevents_insert(monkeypatch):
    from app import main
    original = main.execute_patient_write

    async def undo_then_insert(auth, query, params=()):
        await record_dose_retraction(auth, DoseRetractionCreate(event_uuid='racing-undo', retracted_event_uuid='racing-dose'))
        return await original(auth, query, params)

    monkeypatch.setattr(main, 'execute_patient_write', undo_then_insert)
    response = TestClient(app).post('/api/v1/medication/dose', headers=headers(), json={'event_uuid':'racing-dose'})
    assert response.json()['status'] == 'retracted_ignored'
    assert fetch_one_sync('SELECT COUNT(*) AS n FROM medication_logs')['n'] == 0


def test_write_that_already_holds_the_lock_is_deleted_by_the_following_wipe():
    holding = threading.Event(); release = threading.Event(); wipe_started = threading.Event()
    patient = settings.cadence_default_patient_id

    def insert(conn):
        conn.execute("INSERT INTO medication_logs(patient_id,event_uuid,timestamp_utc,event_type) VALUES(?, 'locked-dose', ?, 'dose_taken')",(patient, SLIGHTLY_AHEAD))
        holding.set()
        assert release.wait(timeout=3)

    def erase():
        wipe_started.set()
        return wipe_patient_data_sync(patient)

    with ThreadPoolExecutor(max_workers=2) as pool:
        writer = pool.submit(patient_transaction_sync, patient, 0, insert)
        assert holding.wait(timeout=3)
        wipe = pool.submit(erase)
        assert wipe_started.wait(timeout=3)
        release.set()
        writer.result(timeout=3)
        assert wipe.result(timeout=3)['data_generation'] == 1
    assert fetch_one_sync('SELECT COUNT(*) AS n FROM medication_logs')['n'] == 0
