#!/usr/bin/env python3
"""Verify the isolated cloud demo; print checks, never passwords or JWTs.

Uses the private reviewer credential and a fixed public model preview.
--after-restart verifies the original read-only token.
"""
import argparse
import json
import os
import ssl
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from dotenv import dotenv_values
import certifi

DIRECTORY = Path(__file__).resolve().parents[1] / '.local/gcp-demo'


def verify(base: str, after_restart: bool):
    if not base.startswith('https://'):
        raise ValueError('A public HTTPS origin is required.')
    base = base.rstrip('/')
    state_path = DIRECTORY / 'judge-acceptance.json'
    tls = ssl.create_default_context(cafile=certifi.where())

    def request(path, expected=200, token=None, payload=None, post=False):
        headers = {'Content-Type': 'application/json'}
        if token:
            headers['Authorization'] = 'Bearer ' + token
        req = Request(base + path, headers=headers, method="POST" if post or payload is not None else "GET",
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
        result = request('/api/v1/auth/login', payload={
            'username': 'demo-reviewer', 'password': credentials['DEMO_READER_PASSWORD'],
        })
        assert result['role'] == 'clinician_reader'
        state = {'origin': base, 'reader': result['access_token']}
        request('/api/v1/auth/login', expected=401, payload={
            'username': 'demo-wearer', 'password': 'cadence-demo-2026',
        })
        request('/api/v1/judge-demo/intent', expected=400, payload={'text': 'Unexpected input'})
        result = request('/api/v1/judge-demo/intent', post=True)
        assert result.get('source') == 'meta_open_weights', 'Live Meta classification did not complete'
        print('PASS: retired writer, fixed demo input and live Meta classification')
    request('/api/v1/companion/interpret', expected=403, token=state['reader'],
            payload={'text': 'What can you do?', 'history': []})
    report = request('/api/v1/report/neurologist', token=state['reader'])
    assert report['patient_id'] == 'hackathon-demo'
    if not after_restart:
        fd = os.open(state_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, 'w') as handle:
            json.dump(state, handle)
        state_path.chmod(0o600)
    print('PASS: scoped reviewer access and writer API rejection' +
          (' using the original JWT after restart' if after_restart else ''))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('origin')
    parser.add_argument('--after-restart', action='store_true')
    args = parser.parse_args()
    verify(args.origin, args.after_restart)
