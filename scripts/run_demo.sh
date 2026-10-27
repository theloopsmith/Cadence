#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR/backend"

if [ ! -d ".venv" ]; then
  echo "Creating Python virtual environment..."
  python3 -m venv .venv
  .venv/bin/pip install -q -r requirements.txt
fi

echo "Running Cadence automated test suite..."
.venv/bin/pytest -q

echo ""
echo "=================================================================="
echo "Starting Cadence Clinical Orchestrator on http://127.0.0.1:8000"
echo "Neurologist Dashboard: http://127.0.0.1:8000/dashboard"
echo "Default Clinician Token: cadence-dev-clinician-reader-token-2026"
echo "=================================================================="
exec .venv/bin/uvicorn app.main:app --host 127.0.0.1 --port 8000 --reload
