"""Writes the fixture `dashboard_browser_security.cjs` loads: the served dashboard
shell, its script, and the headers (including the CSP nonce) exactly as FastAPI
returns them.

    python backend/tests/make_dashboard_fixture.py /tmp/dashboard-shell.json
"""

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from fastapi.testclient import TestClient  # noqa: E402

from app.main import app  # noqa: E402


def main(out_path: str) -> None:
    with TestClient(app) as client:
        shell = client.get("/dashboard")
        script = client.get("/assets/dashboard.js")
    shell.raise_for_status()
    script.raise_for_status()
    fixture = {
        "html": shell.text,
        "headers": dict(shell.headers),
        "script": script.text,
        "script_headers": dict(script.headers),
    }
    Path(out_path).write_text(json.dumps(fixture))
    print(f"wrote {out_path} ({len(shell.text)} html bytes, {len(script.text)} script bytes)")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "/tmp/dashboard-shell.json")
