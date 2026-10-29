"""Default product boundaries and emergency HTTP/ownership contracts."""
import asyncio
import pytest
from fastapi import HTTPException
from fastapi.testclient import TestClient
from app.config import settings
from app.db import init_db_sync, fetch_one_sync
from app.main import app
from app.clients.twilio_client import twilio_client
from app.models import FallEventCreate
from app.services.fall_escalation import FallEscalationManager
from app.services.reality_check import render_grounded_template

@pytest.fixture
def http(monkeypatch, tmp_path):
    monkeypatch.setattr(settings, 'sqlite_db_path', str(tmp_path / 'boundary.db'))
    monkeypatch.setattr(settings, 'enable_research_metrics', False)
    init_db_sync()
    with TestClient(app) as client:
        yield client

def headers():
    return {'Authorization': f'Bearer {settings.cadence_device_token}'}

def fall(uuid='boundary-fall', status='confirmed_waiting_dispatch'):
    return FallEventCreate(event_uuid=uuid, peak_impact_g=3, peak_jerk_gs=40,
                           post_impact_tilt_deg=60, status=status)

def test_production_never_simulates_even_when_demo_flag_is_set(monkeypatch):
    monkeypatch.setattr(settings, 'cadence_env', 'production')
    monkeypatch.setattr(settings, 'demo_mode', True)
    result = asyncio.run(twilio_client.dispatch_sms_and_call('+15550001111', 'prod-001', 3, '2026-10-28T12:00:00Z'))
    assert result['sms_sid'] == result['call_sid'] == ''
    assert result['delivery_status'] == 'unconfigured'
    clear = asyncio.run(twilio_client.send_all_clear_sms('+15550001111', 'prod-001'))
    assert clear['sms_sid'] == ''

def test_total_dispatch_failure_is_http_retryable(http, monkeypatch):
    async def fail(**kwargs):
        return {'sms_sid': '', 'call_sid': '', 'delivery_status': 'failed'}
    monkeypatch.setattr(twilio_client, 'dispatch_sms_and_call', fail)
    result = http.post('/api/v1/events/fall', headers=headers(), json=fall().model_dump())
    assert result.status_code == 503
    assert fetch_one_sync('SELECT status FROM fall_events WHERE event_uuid=?', ('boundary-fall',))['status'] == 'confirmed_waiting_dispatch'

def test_foreign_owner_cannot_cancel_or_mutate_a_candidate(http):
    async def run():
        manager = FallEscalationManager()
        await manager.ingest_fall_event('wearer-A', fall(status='candidate_check_in_pending'), False)
        with pytest.raises(HTTPException) as error:
            await manager.ingest_fall_event('wearer-B', fall(status='canceled_false_alarm'), False)
        assert error.value.status_code == 404
        with pytest.raises(HTTPException):
            await manager.cancel_dispatched_fall('wearer-B', 'boundary-fall')
    asyncio.run(run())
    row = fetch_one_sync('SELECT patient_id,status FROM fall_events WHERE event_uuid=?', ('boundary-fall',))
    assert row == {'patient_id': 'wearer-A', 'status': 'candidate_check_in_pending'}

def test_meal_logging_uses_no_inference_or_nutrition_claim(http, monkeypatch):
    async def forbidden(**kwargs):
        raise AssertionError('Meal logging must not request segmentation')
    from app.clients.meta_models import meta_client
    monkeypatch.setattr(meta_client, 'segment_sam_3_1', forbidden)
    result = http.post('/api/v1/meals/log', headers=headers(), json={'event_uuid': 'meal-boundary'})
    assert result.status_code == 200
    body = result.json()
    assert body['estimated_protein_grams'] is None
    assert body['conflict_detected'] is False
    assert body['spoken_response'] == 'Meal time logged in your routine diary.'

def test_default_report_omits_interpreted_states(http):
    body = http.get('/api/v1/report/neurologist', headers=headers()).json()
    assert 'on_pct' not in body['summary_stats']
    assert all('clinical_state' not in bucket and 'symptom_burden_score' not in bucket for bucket in body['buckets_24h'])

def test_empty_scene_never_claims_safety_or_absence():
    text = render_grounded_template('REASSURE_EMPTY_SPACE')
    assert 'cannot identify' in text.lower()
    for forbidden in ['safe', 'no one', 'clear and']:
        assert forbidden not in text.lower()

def test_unsigned_production_callbacks_are_refused(http, monkeypatch):
    monkeypatch.setattr(settings, 'cadence_env', 'production')
    result = http.post('/api/v1/webhooks/twilio/gather?event_uuid=missing', data={'Digits': '1'})
    assert result.status_code == 503

def test_default_task_completion_and_history_do_not_return_health_scores(http):
    result = http.post('/api/v1/exam/complete', headers=headers(), json={
        'exam_uuid': 'accessibility-task', 'voice_mean_dbfs': -24,
        'voice_stability_db': 2, 'handwriting_opencv_decay_pct': -10,
        'walk_cadence_spm': 90, 'walk_mean_fi': 1, 'walk_fog_count': 0,
    })
    assert result.status_code == 200
    assert set(result.json()) == {'exam_uuid', 'clinical_summary'}
    exams = http.get('/api/v1/exam/history', headers=headers()).json()['exams']
    assert len(exams) == 1
    assert 'composite_motor_score' not in exams[0]
    assert 'medication_state_label' not in exams[0]
