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

echo ""
echo "=================================================================="
echo "Starting Cadence Clinical Orchestrator on http://127.0.0.1:8000"
echo "Neurologist Dashboard: http://127.0.0.1:8000/dashboard"
echo "Default Clinician Token: cadence-dev-clinician-reader-token-2026"
echo "=================================================================="
exec .venv/bin/python3 -m uvicorn app.main:app --host 127.0.0.1 --port 8000 --reload
