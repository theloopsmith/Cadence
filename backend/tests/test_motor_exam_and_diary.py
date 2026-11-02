from datetime import datetime, timezone
from app.services.diary_engine import build_24h_diary_timeline






def test_demo_seed_and_neurologist_report_endpoint():
    from fastapi.testclient import TestClient
    from app.main import app

    headers = {"Authorization": "Bearer cadence-dev-device-writer-token-2026"}
    with TestClient(app) as client:
        seed_res = client.post("/api/v1/demo/seed", headers=headers)
        assert seed_res.status_code == 200
        assert seed_res.json()["status"] == "seeded"

        rep_res = client.get("/api/v1/report/neurologist", headers=headers)
        assert rep_res.status_code == 200
        body = rep_res.json()
        assert len(body["motor_exams"]) >= 2
        assert len(body["buckets_24h"]) >= 8
        assert "exam_on_vs_off_delta" not in body["summary_stats"]
