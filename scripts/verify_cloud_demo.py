#!/usr/bin/env python3
"""Verify the isolated cloud demo; print checks, never passwords or JWTs.

Uses only the private deployment credentials. The initial pass writes one
clearly labeled synthetic dose. --after-restart checks that same record and
the original tokens without issuing replacement tokens.
"""
import argparse
import json
import os
import ssl
from pathlib import Path
import uuid
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from dotenv import dotenv_values
import certifi

DIRECTORY = Path(__file__).resolve().parents[1] / '.local/gcp-demo'


def verify(base: str, after_restart: bool):
    if not base.startswith('https://'):
        raise ValueError('A public HTTPS origin is required.')
    base = base.rstrip('/')
    state_path = DIRECTORY / 'acceptance.json'
    tls = ssl.create_default_context(cafile=certifi.where())

    def request(path, expected=200, token=None, payload=None):
        headers = {'Content-Type': 'application/json'}
        if token:
            headers['Authorization'] = 'Bearer ' + token
        req = Request(base + path, headers=headers,
                      data=json.dumps(payload).encode() if payload is not None else None)
        try:
            with urlopen(req, timeout=30, context=tls) as response:
                code, body = response.status, response.read()
        except HTTPError as error:
            code, body = error.code, error.read()
        if code != expected:
            raise RuntimeError(f'{path}: expected HTTP {expected}, got {code}')
        return json.loads(body) if body and not path.startswith('/dashboard') else None

    assert request('/health')['status'] == 'ok'
    request('/dashboard')
    request('/api/v1/report/neurologist', expected=401)
    request('/api/v1/report/neurologist', expected=401,
            token='cadence-dev-device-writer-token-2026')
    print('PASS: HTTPS, dashboard, anonymous access and shared development token rejection')
    if after_restart:
        state = json.loads(state_path.read_text())
        if state['origin'] != base:
            raise RuntimeError('Restart baseline belongs to a different server.')
    else:
        credentials = dotenv_values(DIRECTORY / 'accounts.env')
        state = {'origin': base, 'event_uuid': 'cloud-smoke-' + str(uuid.uuid4())}
        for key, username, role in [('writer', 'demo-wearer', 'device_writer'),
                                    ('reader', 'demo-reviewer', 'clinician_reader')]:
            result = request('/api/v1/auth/login', payload={
                'username': username,
                'password': credentials['DEMO_' + key.upper() + '_PASSWORD'],
            })
            assert result['role'] == role
            state[key] = result['access_token']
    connection = request('/api/v1/device/connection', token=state['writer'])
    if connection['patient_id'] != 'hackathon-demo':
        raise RuntimeError('Refusing to write outside the isolated demo patient.')
    request('/api/v1/companion/interpret', expected=403, token=state['reader'],
            payload={'text': 'What can you do?', 'history': []})
    if not after_restart:
        state['server_id'] = connection['server_id']
        result = request('/api/v1/companion/interpret', token=state['writer'],
                         payload={'text': 'Catch me up on my pill log from this morning', 'history': []})
        if result.get('source') != 'meta_open_weights':
            raise RuntimeError('Live Meta model classification did not complete.')
        print('PASS: live Meta model classification (' + result['model'] + ')')
        request('/api/v1/medication/dose', token=state['writer'], payload={
            'event_uuid': state['event_uuid'], 'medication_name': 'SYNTHETIC DEPLOYMENT CHECK',
        })
        fd = os.open(state_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, 'w') as handle:
            json.dump(state, handle)
        state_path.chmod(0o600)
    assert connection['server_id'] == state['server_id'], 'Server identity changed'
    report = request('/api/v1/report/neurologist', token=state['reader'])
    assert report['patient_id'] == 'hackathon-demo'
    assert any(row['event_uuid'] == state['event_uuid'] for row in report['medication_logs'])
    print('PASS: scoped login, reader write rejection, synthetic record and server identity' +
          (' survive restart using the original JWTs' if after_restart else ''))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('origin')
    parser.add_argument('--after-restart', action='store_true')
    args = parser.parse_args()
    verify(args.origin, args.after_restart)
