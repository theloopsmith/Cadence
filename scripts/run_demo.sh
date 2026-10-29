#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR/backend"

# The repo lives in iCloud Drive. A venv built here gets synced, and iCloud can
# later restore an older copy over it, leaving interpreter symlinks pointing at
# a Python that no longer exists on this machine. Build outside iCloud and link
# it in, rebuilding whenever the linked interpreter will not run.
VENV_HOME="${CADENCE_VENV:-$HOME/Library/Caches/CadenceBuild/venv}"

if ! "$VENV_HOME/bin/python3" -c "import sys" 2>/dev/null; then
  echo "Setting up clean Python virtual environment in $VENV_HOME ..."
  rm -rf "$VENV_HOME"
  python3 -m venv "$VENV_HOME"
  "$VENV_HOME/bin/pip" install --upgrade pip -q
  "$VENV_HOME/bin/pip" install -r requirements.txt -q
fi

# Point ./.venv at it unless it already resolves to a runnable interpreter.
if ! .venv/bin/python3 -c "import sys" 2>/dev/null; then
  rm -rf .venv
  ln -s "$VENV_HOME" .venv
fi

echo "Running Cadence automated test suite..."
.venv/bin/python3 -m pytest -q

# A demo sign-in for the dashboard, created once per database with a fresh
# random password. Nothing is hardcoded; the password is shown only here.
DEMO_USER="demo-care-team"
if ! .venv/bin/python3 -c "
from app.db import init_db_sync, fetch_one_sync
init_db_sync()
raise SystemExit(0 if fetch_one_sync('SELECT 1 FROM users WHERE username = ?', ('$DEMO_USER',)) else 1)
" 2>/dev/null; then
  DEMO_PASSWORD="$(.venv/bin/python3 -c 'import secrets; print(secrets.token_urlsafe(12))')"
  CADENCE_NEW_USER_PASSWORD="$DEMO_PASSWORD" .venv/bin/python3 -m app.manage create-user \
    --username "$DEMO_USER" --role device_writer >/dev/null
  DEMO_NOTE="Dashboard sign-in: $DEMO_USER / $DEMO_PASSWORD  (shown once; save it)"
else
  DEMO_NOTE="Dashboard sign-in: $DEMO_USER (created earlier; add another with python -m app.manage create-user)"
fi

HOST="${CADENCE_HOST:-0.0.0.0}"
PORT="${CADENCE_PORT:-8000}"

echo ""
echo "=================================================================="
echo "Starting Cadence on http://$HOST:$PORT"
echo "Local network address: http://$(ipconfig getifaddr en0 2>/dev/null || echo "127.0.0.1"):$PORT"
echo "Care-team summary: http://127.0.0.1:$PORT/dashboard"
echo "$DEMO_NOTE"
echo "=================================================================="
exec .venv/bin/python3 -m uvicorn app.main:app --host "$HOST" --port "$PORT" --reload
