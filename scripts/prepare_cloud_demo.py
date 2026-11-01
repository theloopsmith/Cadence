#!/usr/bin/env python3
"""Create ignored, reusable demo credentials. Never copies local patient records."""
from pathlib import Path
import os
import secrets
import shlex
from dotenv import dotenv_values

ROOT = Path(__file__).resolve().parents[1]
PROVIDER_FIELDS = (
    'META_API_KEY', 'META_API_BASE_URL', 'META_ASR_BASE_URL', 'META_SAM_MODEL', 'META_STT_MODEL',
    'BASETEN_API_KEY', 'BASETEN_API_BASE_URL', 'BASETEN_MODEL',
    'FIREWORKS_API_KEY', 'FIREWORKS_API_BASE_URL', 'FIREWORKS_LLM_MODEL', 'FIREWORKS_VLM_MODEL',
)


def prepare(hostname: str):
    if not hostname or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-' for c in hostname):
        raise ValueError('Use a DNS hostname without scheme, port or path')
    directory = ROOT / '.local/gcp-demo'
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    env_path = directory / 'backend.env'
    existing = dotenv_values(env_path) if env_path.exists() else {}
    source = dotenv_values(ROOT / 'backend/.env')
    values = {name: os.environ.get(name, source.get(name)) for name in PROVIDER_FIELDS}
    values.update({
        'CADENCE_ENV': 'public_demo', 'JWT_SECRET': existing.get('JWT_SECRET') or secrets.token_urlsafe(48),
        'ALLOW_STATIC_TOKENS': 'false', 'DEMO_MODE': 'true',
        'ENABLE_RESEARCH_METRICS': 'false',
        'SQLITE_DB_PATH': '/var/lib/cadence/data/demo.sqlite',
        'CADENCE_DEFAULT_PATIENT_ID': 'hackathon-demo',
        'PUBLIC_WEBHOOK_BASE_URL': 'https://' + hostname,
        'CAREGIVER_PRIMARY_PHONE': '+12025550100',
        'TWILIO_ACCOUNT_SID': '', 'TWILIO_AUTH_TOKEN': '', 'TWILIO_FROM_PHONE': '',
        'TWILIO_API_KEY_SID': '', 'TWILIO_API_KEY_SECRET': '',
    })
    def write(path, content):
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, 'w') as handle: handle.write(content)
        path.chmod(0o600)
    write(env_path, ''.join(f'{k}={shlex.quote(str(v))}\n' for k, v in values.items() if v is not None))
    accounts = directory / 'accounts.env'
    if not accounts.exists():
        write(accounts, ''.join(f'{name}={shlex.quote(secrets.token_urlsafe(24))}\n'
              for name in ('DEMO_WRITER_PASSWORD', 'DEMO_READER_PASSWORD')))
    print(f'Prepared private deployment files in {directory}. Credential values were not printed.')


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('hostname')
    prepare(parser.parse_args().hostname)
