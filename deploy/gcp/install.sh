#!/usr/bin/env bash
# Run on the VM as root after uploading the code bundle and protected environment.
set -euo pipefail
if [[ $# -ne 2 ]]; then echo 'Usage: install.sh BUNDLE HOSTNAME' >&2; exit 2; fi
bundle=$1
hostname=$2
[[ "$hostname" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]+$ ]] || exit 2
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y python3-venv python3-pip caddy curl
id cadence >/dev/null 2>&1 || useradd --system --home-dir /var/lib/cadence --create-home --shell /usr/sbin/nologin cadence
install -d -o cadence -g cadence -m 750 /opt/cadence/releases /var/lib/cadence/data
install -d -o root -g cadence -m 750 /etc/cadence
release="/opt/cadence/releases/$(date -u +%Y%m%dT%H%M%S)-$$"
install -d -o cadence -g cadence "$release"
tar -xzf "$bundle" -C "$release" --no-same-owner
chown -R cadence:cadence "$release"
runuser -u cadence -- python3 -m venv "$release/venv"
runuser -u cadence -- "$release/venv/bin/pip" install --disable-pip-version-check -q -r "$release/backend/requirements-lock.txt"
# Validate and create isolated accounts before changing the running release.
chown root:cadence /etc/cadence/backend.env /etc/cadence/accounts.env
chmod 640 /etc/cadence/backend.env /etc/cadence/accounts.env
set -a
source /etc/cadence/backend.env
source /etc/cadence/accounts.env
set +a
cd "$release/backend"
runuser -u cadence -- "$release/venv/bin/python" - <<'PYTHON'
import os
from app.auth import validate_security_settings, create_user_sync
from app.db import init_db_sync, fetch_one_sync
os.umask(0o077)
validate_security_settings()
init_db_sync()
os.chmod(os.environ['SQLITE_DB_PATH'], 0o600)
for username, role, password_key in (
    ('demo-wearer', 'device_writer', 'DEMO_WRITER_PASSWORD'),
    ('demo-reviewer', 'clinician_reader', 'DEMO_READER_PASSWORD'),
):
    existing = fetch_one_sync('SELECT role,patient_id FROM users WHERE username=?', (username,))
    if existing:
        if existing['role'] != role or existing['patient_id'] != 'hackathon-demo':
            raise RuntimeError('Existing demo account has a different binding; refusing replacement.')
    else:
        create_user_sync(username, os.environ[password_key], role, 'hackathon-demo')
PYTHON
rm /etc/cadence/accounts.env
ln -sfn "$release" /opt/cadence/current
chown root:cadence /etc/cadence/backend.env
chmod 640 /etc/cadence/backend.env
cat > /etc/systemd/system/cadence.service <<'UNIT'
[Unit]
Description=Cadence isolated public demo
After=network-online.target
Wants=network-online.target
[Service]
User=cadence
Group=cadence
WorkingDirectory=/opt/cadence/current/backend
EnvironmentFile=/etc/cadence/backend.env
ExecStart=/opt/cadence/current/venv/bin/python -m uvicorn app.main:app --host 127.0.0.1 --port 8000 --workers 1 --proxy-headers --forwarded-allow-ips=127.0.0.1
Restart=on-failure
RestartSec=3
TimeoutStopSec=30
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/cadence
[Install]
WantedBy=multi-user.target
UNIT
cat > /etc/caddy/Caddyfile <<CADDY
$hostname {
    encode gzip
    reverse_proxy 127.0.0.1:8000
}
CADDY
caddy validate --config /etc/caddy/Caddyfile
systemctl daemon-reload
systemctl enable cadence caddy
systemctl restart cadence
for attempt in $(seq 1 30); do
    if curl -fsS http://127.0.0.1:8000/health >/dev/null; then break; fi
    sleep 2
done
curl -fsS http://127.0.0.1:8000/health >/dev/null
systemctl reload-or-restart caddy
printf 'Backend started. Verify public HTTPS at https://%s/health before sharing.\n' "$hostname"
