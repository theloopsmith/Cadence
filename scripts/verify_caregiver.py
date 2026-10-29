#!/usr/bin/env python3
"""One explicitly authorized, test-labeled SMS/call and signed acknowledgment drill.

Defaults to preflight only. Uses an isolated SQLite database, a random readiness
nonce and no automatic redial. Never infer acknowledgment from provider acceptance.
"""
import argparse
import asyncio
from datetime import datetime, timezone
import json
import ipaddress
from pathlib import Path
import re
import subprocess
import secrets
import sys
import threading
import time
from urllib.parse import urlparse

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'backend'))
from dotenv import load_dotenv
load_dotenv(ROOT/'backend'/'.env', override=False)
from app.config import settings


def build_verification_app(nonce):
    from contextlib import asynccontextmanager
    from fastapi import FastAPI
    from app.db import init_db
    from app.main import twilio_gather_webhook, twilio_status_webhook
    from app.services.fall_escalation import fall_escalation_manager
    @asynccontextmanager
    async def lifespan(app):
        await init_db()
        await fall_escalation_manager.resume_open_escalations()
        yield
        await fall_escalation_manager.close()
    # There is no dashboard, login, diary, health route, API schema or production
    # dataset on the publicly exposed verification surface.
    app=FastAPI(lifespan=lifespan,openapi_url=None,docs_url=None,redoc_url=None)
    app.add_api_route('/api/v1/webhooks/twilio/gather',twilio_gather_webhook,methods=['POST'])
    app.add_api_route('/api/v1/webhooks/twilio/status',twilio_status_webhook,methods=['POST'])
    @app.get('/verification/'+nonce)
    def readiness(): return {'nonce':nonce,'mode':'isolated-caregiver-test'}
    return app


def provider_preflight(client, recipient, sender):
    try:
        account=client.api.accounts(settings.twilio_account_sid).fetch()
        numbers=client.incoming_phone_numbers.list(phone_number=sender,limit=1)
        capabilities=numbers[0].capabilities if numbers else {}
        allowed=account.type.lower()!='trial'
        if not allowed:
            allowed=bool(client.outgoing_caller_ids.list(phone_number=recipient,limit=1)) or bool(client.incoming_phone_numbers.list(phone_number=recipient,limit=1))
        return {'account_active':account.status=='active','account_type':account.type,
                'owned_sender_sms_voice_ready':bool(capabilities.get('SMS') or capabilities.get('sms')) and bool(capabilities.get('voice') or capabilities.get('Voice')),
                'trial_recipient_ready':allowed}
    except Exception as exc:
        return {'account_active':False,'provider_preflight_error':type(exc).__name__,'provider_error_code':getattr(exc,'code',None)}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--to',required=True,help='Consenting caregiver in E.164 format')
    parser.add_argument('--public-base-url',default=settings.public_webhook_base_url)
    parser.add_argument('--port',type=int,default=8063)
    parser.add_argument('--tunnel-binary',help='Official cloudflared executable for an explicitly approved temporary tunnel')
    parser.add_argument('--approve-callback-only-tunnel',action='store_true',help='Explicit authorization for at most five minutes of callback-only public exposure')
    parser.add_argument('--provider-preflight',action='store_true',help='Read provider account/sender/Trial recipient readiness without sending or opening a tunnel')
    parser.add_argument('--send',action='store_true',help='Send one scheduled test SMS and one call (no automatic redial)')
    parser.add_argument('--timeout',type=int,default=180)
    parser.add_argument('--evidence',default='/private/tmp/cadence-caregiver-verification.json')
    args=parser.parse_args()
    url=urlparse(args.public_base_url)
    checks={
        'recipient_e164':bool(re.fullmatch(r'\+[1-9][0-9]{7,14}',args.to)),
        'credentials_configured':bool(settings.twilio_account_sid and settings.twilio_auth_token and settings.twilio_from_phone),
        'public_https_callback':url.scheme=='https' and bool(url.hostname) and url.hostname not in ('localhost','127.0.0.1','0.0.0.0','::1') and not url.username and not url.password,
    }
    evidence={'stage':'preflight','verified_at_utc':datetime.now(timezone.utc).isoformat(),'checks':checks,
              'recipient_last4':args.to[-4:],'sent':False,'caregiver_acknowledged':False,'device_mode':'not_part_of_this_transport_drill'}
    def save():
        Path(args.evidence).write_text(json.dumps(evidence,indent=2)+'\n')
    auto_tunnel=bool(args.tunnel_binary and args.approve_callback_only_tunnel)
    if not checks['recipient_e164'] or not checks['credentials_configured'] or (not checks['public_https_callback'] and not auto_tunnel and not args.provider_preflight):
        save();print(json.dumps(evidence));return 2
    if args.send or args.provider_preflight:
        from twilio.rest import Client
        from twilio.http.http_client import TwilioHttpClient
        readiness=provider_preflight(Client(settings.twilio_account_sid,settings.twilio_auth_token,http_client=TwilioHttpClient(timeout=5)),args.to,settings.twilio_from_phone)
        evidence['provider_preflight']=readiness
        provider_ready=all(readiness.get(k) for k in ('account_active','owned_sender_sms_voice_ready','trial_recipient_ready'))
        if not provider_ready or args.provider_preflight:
            evidence['stage']='provider_preflight';evidence['result']='ready_for_test' if provider_ready else 'provider_setup_required'
            save();print(json.dumps(evidence));return 0 if provider_ready else 2
    if not args.send:
        save();print('Preflight passed. No messages sent; --send is required.');return 0

    from app.clients.twilio_client import twilio_client
    from app.db import fetch_one_sync
    from app.models import FallEventCreate
    from app.services.fall_escalation import fall_escalation_manager
    import httpx
    import uvicorn

    # Isolated test service. No production records or contacts are read into it.
    nonce=secrets.token_hex(16)
    settings.sqlite_db_path=f'/private/tmp/cadence-transport-{nonce}.sqlite'
    settings.sqlite_encryption_key=''
    settings.cadence_env='production';settings.demo_mode=False;settings.allow_static_tokens=False
    settings.jwt_secret=secrets.token_urlsafe(48)
    settings.caregiver_primary_phone=args.to;settings.caregiver_secondary_phone=''
    settings.public_webhook_base_url=args.public_base_url.rstrip('/')
    args.timeout=min(180,max(10,args.timeout))
    settings.recovery_poll_sec=args.timeout+60
    settings.max_retry_attempts=0  # one test call, never a surprise repeat dial
    settings.secondary_escalation_delay_sec=args.timeout+60
    settings.retry_window_sec=args.timeout+60
    original=twilio_client.dispatch_sms_and_call
    async def test_dispatch(**kwargs):
        return await original(**kwargs,test_only=True)
    twilio_client.dispatch_sms_and_call=test_dispatch

    app=build_verification_app(nonce)
    server=uvicorn.Server(uvicorn.Config(app,host='127.0.0.1',port=args.port,log_level='warning',access_log=False))
    thread=threading.Thread(target=server.run,daemon=True);thread.start()
    tunnel=None; tunnel_log=None
    try:
        until=time.monotonic()+10
        while not server.started and thread.is_alive() and time.monotonic()<until: time.sleep(0.1)
        if not server.started: raise RuntimeError('Isolated verification server did not start')
        evidence['stage']='isolated_server_ready';save()
        if auto_tunnel:
            # Bind our restricted app BEFORE exposing the port. A separate
            # supervisor enforces a hard lifetime even if this verifier exits.
            tunnel_path=Path('/private/tmp/cadence-callback-tunnel.log')
            tunnel_log=tunnel_path.open('w')
            supervisor="""import subprocess,signal,sys
p=subprocess.Popen(sys.argv[1:])
signal.signal(signal.SIGTERM,lambda *_:p.terminate())
try:p.wait(timeout=295)
except subprocess.TimeoutExpired:
 p.terminate()
 try:p.wait(timeout=5)
 except subprocess.TimeoutExpired:p.kill()
"""
            tunnel=subprocess.Popen([sys.executable,'-c',supervisor,args.tunnel_binary,'tunnel','--no-autoupdate','--config','/dev/null','--url',f'http://127.0.0.1:{args.port}'],stdout=tunnel_log,stderr=subprocess.STDOUT)
            until=time.monotonic()+40
            address=None
            while time.monotonic()<until and tunnel.poll() is None:
                text=tunnel_path.read_text()
                match=re.search(r'https://[a-zA-Z0-9-]+\.trycloudflare\.com',text)
                if match and 'Registered tunnel connection' in text:
                    address=match.group(0);break
                time.sleep(0.2)
            if not address: raise RuntimeError('Temporary callback tunnel did not become ready')
            settings.public_webhook_base_url=address
            checks['public_https_callback']=True

        # A reachable but wrong/public production service must NOT authorize sending.
        evidence['stage']='public_readiness';save()
        until=time.monotonic()+20
        while True:
            try:
                response=httpx.get(settings.public_webhook_base_url+'/verification/'+nonce,timeout=3)
                response.raise_for_status()
                if response.json().get('nonce')!=nonce: raise RuntimeError('Public URL does not reach this isolated test server')
                break
            except httpx.HTTPError:
                # Newly created tunnel names can be absent from the Mac's DNS
                # cache while already present in authoritative public DNS. Use
                # per-request resolution only; retain hostname TLS validation.
                if auto_tunnel:
                    hostname=urlparse(settings.public_webhook_base_url).hostname
                    try:
                        dns=httpx.get('https://cloudflare-dns.com/dns-query',params={'name':hostname,'type':'A'},headers={'Accept':'application/dns-json'},timeout=4).json()
                        addresses=[a['data'] for a in dns.get('Answer',[]) if a.get('type')==1 and ipaddress.ip_address(a['data']).is_global]
                        proved=False
                        for address in addresses:
                            proof=subprocess.run(['curl','--fail','--silent','--show-error','--max-time','4','--resolve',f'{hostname}:443:{address}',settings.public_webhook_base_url+'/verification/'+nonce],capture_output=True,text=True)
                            if proof.returncode==0 and json.loads(proof.stdout).get('nonce')==nonce:
                                evidence['readiness_resolution']='validated_public_dns';proved=True;break
                        if proved:break
                    except (httpx.HTTPError,ValueError,KeyError):pass
                if time.monotonic()>=until: raise
                time.sleep(1)
        evidence['stage']='dispatch_requested';save()
        event_uuid='cadence-test-'+nonce
        result=asyncio.run(fall_escalation_manager.ingest_fall_event('verification-only',FallEventCreate(
            event_uuid=event_uuid,peak_impact_g=0,peak_jerk_gs=0,post_impact_tilt_deg=0),False))
        evidence.update({'sent':bool(result.get('provider_accepted')),'event_uuid':event_uuid,
                         'sms_sid':result.get('sms_sid'),'call_sid':result.get('call_sid')})
        evidence['stage']='awaiting_caregiver_ack';save();print('Scheduled test attempted. Waiting for signed, correlated DTMF acknowledgment.',flush=True)
        until=time.monotonic()+args.timeout
        while time.monotonic()<until:
            row=fetch_one_sync('SELECT acknowledged_at,simulated,call_status FROM fall_attempts WHERE event_uuid=? ORDER BY attempt_no DESC LIMIT 1',(event_uuid,))
            if row and row['acknowledged_at'] and not row['simulated']:
                evidence['caregiver_acknowledged']=True;break
            time.sleep(1)
        evidence['stage']='finished'
        evidence['result']='verified' if evidence['caregiver_acknowledged'] else 'not_verified'
        save();print(json.dumps(evidence));return 0 if evidence['caregiver_acknowledged'] else 3
    except Exception as exc:
        # Never print provider exception payloads, tokens, full contacts or request headers.
        evidence['result']='not_verified';evidence['failure_type']=type(exc).__name__
        if evidence.get('stage')=='public_readiness': evidence['readiness_error']=str(exc)[:160]
        save();print(json.dumps(evidence));return 2
    finally:
        if tunnel is not None:
            tunnel.terminate()
            try:tunnel.wait(timeout=6)
            except subprocess.TimeoutExpired:tunnel.kill()
        if tunnel_log is not None:tunnel_log.close()
        server.should_exit=True;thread.join(timeout=5)

if __name__=='__main__': raise SystemExit(main())
