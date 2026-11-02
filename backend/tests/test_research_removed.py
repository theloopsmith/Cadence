"""Retired features cannot be re-enabled or exposed by stale configuration/data."""
from pathlib import Path
import importlib.util
from fastapi.testclient import TestClient
from app.config import Settings
from app.main import app
from app.responses import observation_projection


def test_old_environment_switch_cannot_restore_removed_paths(monkeypatch):
    monkeypatch.setenv("ENABLE_RESEARCH_METRICS", "true")
    config = Settings(_env_file=None)
    assert "enable_research_metrics" not in type(config).model_fields
    assert importlib.util.find_spec("app.services.motor_exam") is None
    assert importlib.util.find_spec("app.services.protein_checker") is None
    with TestClient(app) as http:
        assert http.post("/api/v1/medication/meal-protein", json={}).status_code == 404
        schema = http.get("/openapi.json").json()
    assert "/api/v1/medication/meal-protein" not in schema["paths"]
    for name in ("MotorExamResponse", "SummaryStats"):
        assert not ({"composite_motor_score", "voice_score", "handwriting_score", "gait_score", "medication_state_label", "on_pct"} & schema["components"]["schemas"][name]["properties"].keys())


def test_legacy_findings_are_removed_recursively_without_losing_observations():
    result = observation_projection({"exams": [{"voice_mean_dbfs": -25, "voice_score": 90, "composite_motor_score": 87, "medication_state_label": "ON"}],
        "meals": [{"timestamp_utc": "2026-01-01", "estimated_protein_grams": 30, "conflict_detected": True, "detected_foods_json": "[]", "plate_detected": 1}]})
    assert result == {"exams": [{"voice_mean_dbfs": -25}], "meals": [{"timestamp_utc": "2026-01-01"}]}
