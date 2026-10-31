import asyncio
import os
from pathlib import Path
import subprocess
import sys
import time

import pytest
from app.config import settings
from app.db import init_db_sync, execute_write_sync, fetch_all_sync, fetch_one_sync
from app.models import FallEventCreate
from app.services.fall_escalation import FallEscalationManager
from app.clients.twilio_client import twilio_client

@pytest.fixture
def db(monkeypatch,tmp_path):
    path=tmp_path/'durable.db'
    monkeypatch.setattr(settings,'sqlite_db_path',str(path))
    monkeypatch.setattr(settings,'sqlite_encryption_key','')
    monkeypatch.setattr(settings,'secondary_escalation_delay_sec',30)
    init_db_sync()
    return path

@pytest.fixture
def calls(monkeypatch):
    sent=[]
    async def dispatch(**kw):
        sent.append(kw)
        return {'sms_sid':f'SM{len(sent):032d}','call_sid':f'CA{len(sent):032d}','delivery_status':'queued','sms_body':'test'}
    monkeypatch.setattr(twilio_client,'dispatch_sms_and_call',dispatch)
    return sent

def event(uuid='durable-event',status='confirmed_waiting_dispatch'):
    return FallEventCreate(event_uuid=uuid,status=status,peak_impact_g=3,peak_jerk_gs=40,post_impact_tilt_deg=60)


def test_process_death_during_provider_call_recovers_committed_attempt(db,calls):
    # Genuine process exit after commit, not a cleanly cancelled asyncio task.
    code='''import asyncio,os,sys
from app.config import settings
settings.sqlite_db_path=sys.argv[1];settings.sqlite_encryption_key=''
from app.db import init_db_sync
from app.services.fall_escalation import FallEscalationManager
from app.models import FallEventCreate
from app.clients.twilio_client import twilio_client
init_db_sync()
async def crash(**kw): os._exit(71)
twilio_client.dispatch_sms_and_call=crash
asyncio.run(FallEscalationManager().ingest_fall_event('owner',FallEventCreate(event_uuid='crash-event',peak_impact_g=3,peak_jerk_gs=40,post_impact_tilt_deg=60),False))
'''
    result=subprocess.run([sys.executable,'-c',code,str(db)],cwd=Path(__file__).parents[1],timeout=30)
    assert result.returncode==71
    attempt=fetch_one_sync("SELECT * FROM fall_attempts WHERE event_uuid='crash-event'")
    assert attempt['state']=='in_flight'
    execute_write_sync("UPDATE fall_jobs SET lease_until=0,next_due=0 WHERE event_uuid='crash-event'")
    asyncio.run(FallEscalationManager().recover_due_once())
    rows=fetch_all_sync("SELECT * FROM fall_attempts WHERE event_uuid='crash-event' ORDER BY attempt_no")
    assert [r['state'] for r in rows]==['delivery_unknown','accepted']
    assert len(calls)==1


def test_candidate_timeout_survives_loss_of_phone_or_process(db,calls):
    asyncio.run(FallEscalationManager().ingest_fall_event('owner',event(status='candidate_check_in_pending'),False))
    assert not calls
    execute_write_sync("UPDATE fall_jobs SET next_due=0 WHERE event_uuid='durable-event'")
    asyncio.run(FallEscalationManager().recover_due_once())
    assert len(calls)==1
    assert fetch_one_sync("SELECT status FROM fall_events WHERE event_uuid='durable-event'")['status']=='escalated_twilio'


def test_candidate_timeout_dispatches_after_the_wearer_once_reset_their_data(db,calls):
    """A past 'Reset Diary Data' must not fence the server's own recovery of a later fall."""
    execute_write_sync("INSERT INTO patient_wipes (patient_id, wiped_at_utc) VALUES ('owner','2026-01-01T00:00:00+00:00')")
    asyncio.run(FallEscalationManager().ingest_fall_event('owner',event(status='candidate_check_in_pending'),False,data_generation=1))
    execute_write_sync("UPDATE fall_jobs SET next_due=0 WHERE event_uuid='durable-event'")
    asyncio.run(FallEscalationManager().recover_due_once())
    assert len(calls)==1
    assert fetch_one_sync("SELECT status FROM fall_events WHERE event_uuid='durable-event'")['status']=='escalated_twilio'


def test_one_broken_job_does_not_starve_the_others(db,calls,monkeypatch):
    """The sweep must keep going past a job that raises, or one row blocks every wearer's recovery."""
    asyncio.run(FallEscalationManager().ingest_fall_event('a',event(uuid='bad-event',status='candidate_check_in_pending'),False))
    asyncio.run(FallEscalationManager().ingest_fall_event('b',event(uuid='good-event',status='candidate_check_in_pending'),False))
    execute_write_sync("UPDATE fall_jobs SET next_due=0")
    manager=FallEscalationManager()
    real=manager.ingest_fall_event
    async def flaky(patient_id,payload,*a,**kw):
        if payload.event_uuid=='bad-event': raise RuntimeError('corrupt row')
        return await real(patient_id,payload,*a,**kw)
    monkeypatch.setattr(manager,'ingest_fall_event',flaky)
    asyncio.run(manager.recover_due_once())
    assert len(calls)==1
    assert fetch_one_sync("SELECT status FROM fall_events WHERE event_uuid='good-event'")['status']=='escalated_twilio'


def test_failed_dispatch_is_retried_without_another_phone_request(db,calls,monkeypatch):
    real=twilio_client.dispatch_sms_and_call
    async def fail(**kw): raise OSError('offline')
    monkeypatch.setattr(twilio_client,'dispatch_sms_and_call',fail)
    asyncio.run(FallEscalationManager().ingest_fall_event('owner',event(),False))
    monkeypatch.setattr(twilio_client,'dispatch_sms_and_call',real)
    execute_write_sync('UPDATE fall_jobs SET next_due=0')
    asyncio.run(FallEscalationManager().recover_due_once())
    assert len(calls)==1


def test_concurrent_recovery_workers_claim_one_attempt(db,calls):
    asyncio.run(FallEscalationManager().ingest_fall_event('owner',event(status='candidate_check_in_pending'),False))
    execute_write_sync('UPDATE fall_jobs SET next_due=0')
    async def run():
        await asyncio.gather(FallEscalationManager().recover_due_once(),FallEscalationManager().recover_due_once())
    asyncio.run(run())
    assert len(calls)==1


def test_stale_recovery_retry_cannot_bypass_next_due(db,calls):
    async def run():
        m=FallEscalationManager()
        await m.ingest_fall_event('owner',event(),False)
        execute_write_sync('UPDATE fall_jobs SET next_due=0')
        await m.escalate_to_secondary_or_retry_primary('owner','durable-event',1,expected_attempt_no=0)
        await m.escalate_to_secondary_or_retry_primary('owner','durable-event',1,expected_attempt_no=0)
    asyncio.run(run())
    assert len(calls)==2
    assert fetch_one_sync('SELECT attempt_no FROM fall_jobs')['attempt_no']==1


def test_phone_retry_cannot_restart_failed_initial_attempt(db,monkeypatch):
    sent=[]
    async def fail(**kw):
        sent.append(kw)
        return {'sms_sid':'','call_sid':'','delivery_status':'failed'}
    monkeypatch.setattr(twilio_client,'dispatch_sms_and_call',fail)
    async def run():
        m=FallEscalationManager()
        await m.ingest_fall_event('owner',event(),False)
        await m.ingest_fall_event('owner',event(),False)
    asyncio.run(run())
    assert len(sent)==1


def test_callback_requires_matching_attempt_and_call_identity(db,calls):
    async def run():
        m=FallEscalationManager()
        await m.ingest_fall_event('owner',event(),False)
        attempt=fetch_one_sync('SELECT * FROM fall_attempts')
        bad=await m.handle_gather_webhook('durable-event','1',call_sid='CAwrong',attempt_id=attempt['attempt_id'])
        assert not bad['acknowledged']
        good=await m.handle_gather_webhook('durable-event','1',call_sid=attempt['call_sid'],attempt_id=attempt['attempt_id'])
        assert good['acknowledged'] and not good['simulated']
        status=await m.delivery_status('owner','durable-event')
        assert status['caregiver_acknowledged']
        await m.recover_due_once()
    asyncio.run(run())
    assert len(calls)==1


def test_ack_before_dispatch_response_does_not_get_overwritten_or_send_all_clear(db,monkeypatch):
    m=FallEscalationManager()
    async def dispatch(**kw):
        ack=await m.handle_gather_webhook(kw['event_uuid'],'1',call_sid='CAearly',attempt_id=kw['attempt_id'])
        assert ack['acknowledged']
        return {'sms_sid':'SMearly','call_sid':'CAearly','delivery_status':'queued','sms_body':'test'}
    monkeypatch.setattr(twilio_client,'dispatch_sms_and_call',dispatch)
    asyncio.run(m.ingest_fall_event('owner',event(),False))
    assert fetch_one_sync('SELECT state FROM fall_jobs')['state']=='resolved'
    assert fetch_all_sync('SELECT * FROM fall_clear_jobs')==[]
    assert fetch_one_sync('SELECT state FROM fall_attempts')['state']=='acknowledged'


def test_cancellation_is_durable_and_all_clear_failure_retries(db,calls,monkeypatch):
    async def clear(*args): return {'sms_sid':''}
    monkeypatch.setattr(twilio_client,'send_all_clear_sms',clear)
    async def run():
        m=FallEscalationManager()
        await m.ingest_fall_event('owner',event(),False)
        result=await m.cancel_dispatched_fall('owner','durable-event')
        assert result['all_clear_sms_sent']==0
    asyncio.run(run())
    assert fetch_one_sync('SELECT state FROM fall_jobs')['state']=='resolved'
    assert fetch_one_sync('SELECT state FROM fall_clear_jobs')['state']=='pending'
    async def clear_ok(*args): return {'sms_sid':'SMclear'}
    monkeypatch.setattr(twilio_client,'send_all_clear_sms',clear_ok)
    execute_write_sync('UPDATE fall_clear_jobs SET next_due=0')
    asyncio.run(FallEscalationManager().recover_due_once())
    assert fetch_one_sync('SELECT state FROM fall_clear_jobs')['state']=='sent'
    assert len(calls)==1


def test_expired_jobs_and_stale_workers_cannot_restart_delivery(db,calls):
    asyncio.run(FallEscalationManager().ingest_fall_event('owner',event(status='candidate_check_in_pending'),False))
    execute_write_sync('UPDATE fall_jobs SET deadline=0,next_due=0')
    asyncio.run(FallEscalationManager().recover_due_once())
    assert not calls
    assert fetch_one_sync('SELECT state FROM fall_jobs')['state']=='exhausted'


def test_signed_http_callback_correlates_provider_acceptance_and_caregiver_ack(db,calls,monkeypatch):
    from fastapi.testclient import TestClient
    from twilio.request_validator import RequestValidator
    from app.main import app
    monkeypatch.setattr(settings,'twilio_auth_token','unit-test-webhook-secret')
    monkeypatch.setattr(settings,'public_webhook_base_url','https://cadence-test.example')
    h={'Authorization':f'Bearer {settings.cadence_device_token}'}
    with TestClient(app) as http:
        posted=http.post('/api/v1/events/fall',headers=h,json=event('signed-event').model_dump())
        assert posted.status_code==200
        a=fetch_one_sync("SELECT * FROM fall_attempts WHERE event_uuid='signed-event'")
        path=f"/api/v1/webhooks/twilio/gather?event_uuid=signed-event&attempt_id={a['attempt_id']}"
        data={'Digits':'1','CallSid':a['call_sid']}
        signature=RequestValidator(settings.twilio_auth_token).compute_signature(settings.public_webhook_base_url+path,data)
        refused=http.post(path,data=data,headers={'X-Twilio-Signature':'incorrect'})
        assert refused.status_code==403
        before=http.get('/api/v1/events/fall/signed-event/delivery',headers=h).json()
        assert before['provider_accepted'] and not before['caregiver_acknowledged']
        accepted=http.post(path,data=data,headers={'X-Twilio-Signature':signature})
        assert accepted.status_code==200 and 'Alert acknowledged' in accepted.text
        after=http.get('/api/v1/events/fall/signed-event/delivery',headers=h).json()
        assert after['caregiver_acknowledged'] and after['job']['state']=='resolved'
        unknown=http.get('/api/v1/events/fall/absent/delivery',headers=h)
        assert unknown.status_code==404


def test_lease_fences_a_stale_workers_late_response(db):
    from app.services import fall_durability as d
    async def run():
        m=FallEscalationManager()
        await m.ingest_fall_event('owner',event(status='candidate_check_in_pending'),False)
        execute_write_sync("UPDATE fall_events SET status='confirmed_waiting_dispatch'")
        first=await d.begin('owner','durable-event','primary','+15550001111',0,primary=True)
        execute_write_sync('UPDATE fall_jobs SET lease_until=0')
        second=await d.begin('owner','durable-event','secondary','+15550002222',1)
        await d.finish(second,{'sms_sid':'SMnew','call_sid':'CAnew'})
        await d.finish(first,{'sms_sid':'SMold','call_sid':'CAold'})
    asyncio.run(run())
    assert fetch_one_sync('SELECT caregiver_call_sid FROM fall_events')['caregiver_call_sid']=='CAnew'


def test_cancel_while_provider_request_is_in_flight_stays_canceled_and_sends_clear(db,monkeypatch):
    cleared=[]
    async def run():
        started=asyncio.Event();release=asyncio.Event()
        async def dispatch(**kw):
            started.set();await release.wait()
            return {'sms_sid':'SMraced','call_sid':'CAraced','delivery_status':'queued','sms_body':'test'}
        async def clear(phone,event_uuid):
            cleared.append(event_uuid);return {'sms_sid':'SMclear'}
        monkeypatch.setattr(twilio_client,'dispatch_sms_and_call',dispatch)
        monkeypatch.setattr(twilio_client,'send_all_clear_sms',clear)
        m=FallEscalationManager()
        task=asyncio.create_task(m.ingest_fall_event('owner',event(),False))
        await started.wait()
        result=await m.cancel_dispatched_fall('owner','durable-event')
        assert result['status']=='canceled_false_alarm'
        release.set();await task
    asyncio.run(run())
    assert fetch_one_sync('SELECT status FROM fall_events')['status']=='canceled_false_alarm'
    assert fetch_one_sync('SELECT state FROM fall_jobs')['state']=='resolved'
    assert cleared==['durable-event']


def test_live_verification_server_exposes_only_nonce_and_signed_callbacks(db,monkeypatch):
    import importlib.util
    from fastapi.testclient import TestClient
    path=Path(__file__).parents[2]/'scripts'/'verify_caregiver.py'
    spec=importlib.util.spec_from_file_location('verify_caregiver',path)
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    monkeypatch.setattr(settings,'twilio_auth_token','test-signature-secret')
    http_app=module.build_verification_app('test-nonce')
    with TestClient(http_app) as http:
        assert http.get('/verification/test-nonce').json()['nonce']=='test-nonce'
        for hidden in ['/health','/dashboard','/docs','/openapi.json','/api/v1/report/neurologist']:
            assert http.get(hidden).status_code==404
        assert http.post('/api/v1/auth/login',json={}).status_code==404
        assert http.post('/api/v1/webhooks/twilio/gather?event_uuid=absent',data={'Digits':'1'}).status_code==403


def test_signed_ack_survives_loss_of_the_provider_response(db,monkeypatch):
    m=FallEscalationManager()
    async def dispatch(**kw):
        result=await m.handle_gather_webhook(kw['event_uuid'],'1',call_sid='CAknown_from_signed_callback',attempt_id=kw['attempt_id'])
        assert result['acknowledged']
        raise TimeoutError('provider response lost after callback')
    monkeypatch.setattr(twilio_client,'dispatch_sms_and_call',dispatch)
    result=asyncio.run(m.ingest_fall_event('owner',event(),False))
    assert result['provider_accepted']
    assert fetch_one_sync('SELECT state FROM fall_jobs')['state']=='resolved'
    assert fetch_one_sync('SELECT call_sid FROM fall_attempts')['call_sid']=='CAknown_from_signed_callback'


def test_verifier_preflight_rejects_an_unverified_trial_recipient_without_sending(monkeypatch):
    import importlib.util
    from types import SimpleNamespace as Obj
    path=Path(__file__).parents[2]/'scripts'/'verify_caregiver.py'
    spec=importlib.util.spec_from_file_location('verify_preflight',path)
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    owned=Obj(capabilities={'SMS':True,'voice':True})
    client=Obj(api=Obj(accounts=lambda _:Obj(fetch=lambda:Obj(type='Trial',status='active'))),
               incoming_phone_numbers=Obj(list=lambda phone_number,limit:[owned] if phone_number=='sender' else []),
               outgoing_caller_ids=Obj(list=lambda **kw:[]))
    result=module.provider_preflight(client,'recipient','sender')
    assert result['owned_sender_sms_voice_ready']
    assert not result['trial_recipient_ready']


def test_verifier_preflight_requires_a_sender_that_can_both_call_and_text():
    import importlib.util
    from types import SimpleNamespace as Obj
    path=Path(__file__).parents[2]/'scripts'/'verify_caregiver.py'
    spec=importlib.util.spec_from_file_location('verify_sender',path)
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    client=Obj(api=Obj(accounts=lambda _:Obj(fetch=lambda:Obj(type='Full',status='active'))),
               incoming_phone_numbers=Obj(list=lambda **kw:[Obj(capabilities={'voice':True,'SMS':False})]))
    result=module.provider_preflight(client,'recipient','sender')
    assert result['trial_recipient_ready']
    assert not result['owned_sender_sms_voice_ready']
