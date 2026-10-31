#!/usr/bin/env python3
"""Start the Mac backend for an iPhone on the same LAN; no public tunnel.

Uses a separate development database and simulated caregiver delivery. Model
credentials still come from backend/.env. No credentials are put in a URL.
"""
import argparse
import os
from pathlib import Path
import secrets
import shutil
import socket
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def phone_signing_secret(local: Path) -> str:
    """Keep this isolated phone server's login tokens valid across restarts."""
    path = local / 'phone-jwt-secret'
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        value = path.read_text().strip()
        if len(value) < 32:
            raise ValueError('Phone signing key is incomplete. Preserve it and investigate before restarting; do not silently rotate it.')
        return value
    value = secrets.token_urlsafe(48)
    with os.fdopen(fd, 'w') as handle:
        handle.write(value + '\n')
        handle.flush()
        os.fsync(handle.fileno())
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=int, default=8001)
    args = parser.parse_args()
    if not 1024 <= args.port <= 65535:
        parser.error('port must be between 1024 and 65535')
    python = ROOT / 'backend/.venv/bin/python'
    if not python.exists():
        parser.error('Create backend/.venv and install backend/requirements.txt first.')
    local = ROOT / '.local'
    local.mkdir(mode=0o700, exist_ok=True)
    env = dict(os.environ, SQLITE_DB_PATH=str(local / 'phone-server.sqlite'),
               CADENCE_ENV='development', DEMO_MODE='true', ALLOW_STATIC_TOKENS='true',
               TWILIO_ACCOUNT_SID='', TWILIO_AUTH_TOKEN='', TWILIO_FROM_PHONE='',
               TWILIO_API_KEY_SID='', TWILIO_API_KEY_SECRET='',
               CAREGIVER_PRIMARY_PHONE='', CAREGIVER_SECONDARY_PHONE='')
    # Fail before initializing an account if another server owns the port.
    probe = socket.socket()
    try:
        probe.bind(('0.0.0.0', args.port))
    except OSError:
        parser.error(f'Port {args.port} is already in use. Stop that server or use --port.')
    finally:
        probe.close()
    try:
        env['JWT_SECRET'] = phone_signing_secret(local)
    except (OSError, ValueError) as error:
        parser.error(str(error))
    login = local / 'phone-login.txt'
    if not login.exists():
        password = secrets.token_urlsafe(20)
        username = 'phone-' + secrets.token_hex(2)
        result = subprocess.run([str(python), '-m', 'app.manage', 'create-user', '--username', username,
                                 '--role', 'device_writer'], cwd=ROOT / 'backend',
                                env=dict(env, CADENCE_NEW_USER_PASSWORD=password), capture_output=True, text=True)
        if result.returncode:
            print('Could not create the phone account. Existing database/account data was preserved.', file=sys.stderr)
            return 1
        with open(login, 'x', opener=lambda path, flags: os.open(path, flags, 0o600)) as handle:
            handle.write(f'Username: {username}\nPassword: {password}\n')
    try:
        name = subprocess.check_output(['/usr/sbin/scutil', '--get', 'LocalHostName'], text=True).strip()
    except (OSError, subprocess.CalledProcessError):
        name = socket.gethostname().split('.')[0]
    address = f'http://{name}.local:{args.port}'
    print(f'\nOn the iPhone, Settings → Mac server address: {address}', flush=True)
    print(f'Check in iPhone Safari: {address}/health', flush=True)
    print(f'Phone account credentials: {login}', flush=True)
    print('Keep iPhone and Mac on the same Wi-Fi. Allow Local Network access for Cadence.', flush=True)
    print('Development server: caregiver delivery is SIMULATED. No public tunnel. Ctrl-C to stop.\n', flush=True)
    advertiser = None
    dns_sd = shutil.which('dns-sd')
    if dns_sd:
        advertiser = subprocess.Popen([dns_sd, '-R', f'Cadence on {name}', '_cadence._tcp', 'local', str(args.port)],
                                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        print('In Cadence Settings, tap Find my Mac server. Select this Mac, then sign in.', flush=True)
    try:
        return subprocess.call([str(python), '-m', 'uvicorn', 'app.main:app', '--host', '0.0.0.0', '--port', str(args.port)],
                               cwd=ROOT / 'backend', env=env)
    except KeyboardInterrupt:
        return 0
    finally:
        if advertiser is not None:
            advertiser.terminate()
            advertiser.wait(timeout=5)


if __name__ == '__main__':
    raise SystemExit(main())
