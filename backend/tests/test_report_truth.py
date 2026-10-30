from datetime import datetime, timedelta, timezone
import pytest
from fastapi.testclient import TestClient
from app.config import settings
from app.db import init_db_sync, execute_write_sync
from app.main import app, _within_last_day
from app.services.report_snapshot import snapshot_sync
from app.services.diary_engine import build_24h_diary_timeline
from app.services.delivery_evidence import delivery_evidence

END = datetime(2026,10,29,20,0,tzinfo=timezone.utc)
HEADERS = {'Authorization':'Bearer cadence-dev-device-writer-token-2026'}

@pytest.fixture
def db(monkeypatch,tmp_path):
    monkeypatch.setattr(settings,'sqlite_db_path',str(tmp_path/'report.db'))
    monkeypatch.setattr(settings,'enable_research_metrics',False)
    init_db_sync()

def fog(uuid,at,pid='default_patient'):
    execute_write_sync('''INSERT INTO fog_events(patient_id,event_uuid,timestamp_utc,duration_sec,peak_freeze_index,locomotor_band_power,freeze_band_power,arming_mode)
        VALUES(?,?,?,2,3,1,3,'walking')''',(pid,uuid,at))

def test_exact_utc_window_excludes_stale_future_invalid_and_other_wearers(db):
    start=END-timedelta(hours=24)
    for uuid,at in [('start',start.isoformat()),('before',(start-timedelta(microseconds=1)).isoformat()),
        ('last',(END-timedelta(microseconds=1)).isoformat()),('end',END.isoformat()),
        ('old',(END-timedelta(days=5)).isoformat()),('future',(END+timedelta(days=1)).isoformat()),('invalid','invalid'),
        ('offset','2026-10-29T13:00:00-05:00')]: fog(uuid,at)
    fog('other',(END-timedelta(hours=1)).isoformat(),'other')
    rows=snapshot_sync('default_patient',END)['fog_events']
    assert {r['event_uuid'] for r in rows}=={'start','last','offset'}
    assert rows[0]['event_uuid']=='last'

def test_empty_or_dose_only_periods_do_not_imply_monitoring_or_good_health():
    timeline=build_24h_diary_timeline([],[],[{'timestamp_utc':(END-timedelta(minutes=1)).isoformat(),'event_type':'dose_taken'}],[],[],[],reference_end_utc=END)
    assert len(timeline['buckets'])==48
    assert timeline['unknown_pct']==100
    assert timeline['on_pct']==0
    assert timeline['buckets'][-1]['observation_status']=='events_logged'
    assert all(b['monitoring_coverage']=='unknown' for b in timeline['buckets'])
    assert sum(b['observation_status']=='no_observations' for b in timeline['buckets'])==47
    assert datetime.fromisoformat(timeline['buckets'][0]['bucket_start_utc'])==END-timedelta(hours=24)
    assert datetime.fromisoformat(timeline['buckets'][-1]['bucket_end_utc'])==END

def test_full_interval_totals_are_not_capped_with_detail_rows(db,monkeypatch):
    now=datetime.now(timezone.utc)
    for i in range(130): fog(f'busy-{i}',(now-timedelta(minutes=30,seconds=i)).isoformat())
    fog('stale',(now-timedelta(days=5)).isoformat())
    fog('future',(now+timedelta(days=1)).isoformat())
    # Reports must not depend on a model rephrasing delivery or event counts.
    async def forbidden(*args,**kw): raise AssertionError('report should be factual without inference')
    monkeypatch.setattr('app.main.fireworks_client.summarize_clinical_diary',forbidden)
    report=TestClient(app).get('/api/v1/report/neurologist',headers=HEADERS).json()
    assert report['summary_stats']['fog_count']==130
    assert len(report['fog_events'])==100
    assert report['report_metadata']['details_truncated']['fog_events'] is True
    assert sum(b['fog_count'] for b in report['buckets_24h'])==130
    assert report['report_metadata']['monitoring_coverage']=='unknown'

def test_acceptance_simulation_and_acknowledgment_are_independent_facts():
    fall={'event_uuid':'incident','status':'confirmed_waiting_dispatch'}
    assert delivery_evidence(fall,[])['contact_state']=='queued'
    simulated={'sms_sid':'SM_SIM_1','call_sid':'CA_SIM_1','acknowledged_at':1,'simulated':1}
    proof=delivery_evidence(fall,[simulated])
    assert proof['contact_state']=='simulated' and not proof['provider_accepted'] and not proof['caregiver_acknowledged']
    real={'sms_sid':'SMreal','call_sid':'CAreal','acknowledged_at':None,'simulated':0}
    assert delivery_evidence(fall,[real])['contact_state']=='provider_accepted'
    real['acknowledged_at']=2
    assert delivery_evidence(fall,[real])['contact_state']=='acknowledged'
    assert delivery_evidence({**fall,'caregiver_call_sid':'CAlegacy'},[])['caregiver_acknowledged'] is False

def test_future_timestamp_is_not_within_the_last_day():
    assert not _within_last_day((datetime.now(timezone.utc)+timedelta(days=1)).isoformat())

def test_report_and_delivery_endpoint_share_incident_bound_evidence(db):
    now=datetime.now(timezone.utc)-timedelta(minutes=2)
    for uuid, status in [('queued','confirmed_waiting_dispatch'),('accepted','dispatched'),
        ('ack','dispatched'),('sim','dispatched'),('pending','candidate_check_in_pending'),('canceled','canceled_false_alarm')]:
        execute_write_sync('''INSERT INTO fall_events(patient_id,event_uuid,timestamp_utc,peak_impact_g,
            peak_jerk_gs,post_impact_tilt_deg,pre_impact_wear_rms_g,status)
            VALUES('default_patient',?,?,3,6,70,0.1,?)''',(uuid,now.isoformat(),status))
        execute_write_sync('''INSERT INTO fall_jobs(event_uuid,patient_id,state,next_due,deadline)
            VALUES(?,'default_patient','pending',0,100)''',(uuid,))
    for uuid, sid, ack, simulated in [('accepted','CAreal-1',None,0),('ack','CAreal-2',1,0),('sim','CA_SIM_3',1,1)]:
        execute_write_sync('''INSERT INTO fall_attempts(attempt_id,event_uuid,patient_id,attempt_no,
            contact_role,to_phone,started_at,state,call_sid,acknowledged_at,simulated)
            VALUES(?,?,'default_patient',0,'primary','fixture',0,'accepted',?,?,?)''',(uuid,uuid,sid,ack,simulated))
    http=TestClient(app)
    response=http.get('/api/v1/report/neurologist',headers=HEADERS)
    assert response.status_code==200
    report=response.json(); stats=report['summary_stats']
    assert stats['fall_count']==4
    assert stats['caregiver_provider_accepted_count']==2
    assert stats['caregiver_acknowledged_count']==1
    assert stats['simulated_alert_count']==1
    assert stats['alert_queued_count']==1 and stats['check_in_pending_count']==1
    assert 'caregiver was contacted' not in report['clinical_narrative']
    for fall in report['fall_events']:
        proof=http.get(f"/api/v1/events/fall/{fall['event_uuid']}/delivery",headers=HEADERS).json()
        for key in ['contact_state','provider_accepted','caregiver_acknowledged','simulated']:
            assert proof[key]==fall[key]
