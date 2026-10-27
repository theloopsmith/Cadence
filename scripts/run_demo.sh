#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR/backend"

# Ensure .venv exists and its python interpreter is runnable on this machine
if [ ! -d ".venv" ] || ! .venv/bin/python3 -c "import sys" 2>/dev/null; then
  echo "Setting up clean Python virtual environment..."
  rm -rf .venv
  python3 -m venv .venv
  .venv/bin/pip install --upgrade pip -q
  .venv/bin/pip install -r requirements.txt -q
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
