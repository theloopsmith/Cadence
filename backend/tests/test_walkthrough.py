"""Test interactive smart glasses walkthrough routes, asset delivery, and simulation payloads."""
from starlette.testclient import TestClient
from app.main import app
from app.auth import issue_token


def test_walkthrough_route_delivers_html_and_csp():
    client = TestClient(app)
    response = client.get("/walkthrough")
    assert response.status_code == 200
    assert "text/html" in response.headers["content-type"]
    assert "Cadence on Ray-Ban Meta" in response.text
    assert "Content-Security-Policy" in response.headers
    csp = response.headers["Content-Security-Policy"]
    assert "default-src 'none'" in csp
    assert "script-src 'nonce-" in csp


def test_demo_alias_route_delivers_walkthrough():
    client = TestClient(app)
    response = client.get("/demo")
    assert response.status_code == 200
    assert "Cadence on Ray-Ban Meta" in response.text


def test_walkthrough_javascript_asset():
    client = TestClient(app)
    response = client.get("/assets/walkthrough.js")
    assert response.status_code == 200
    assert "javascript" in response.headers["content-type"]
    assert "localStorage.setItem" not in response.text
    assert "sessionStorage.setItem" not in response.text
    assert "apiCall" in response.text


def test_walkthrough_styles_and_allowlisted_images():
    client = TestClient(app)
    styles = client.get('/assets/walkthrough.css')
    assert styles.status_code == 200
    assert 'text/css' in styles.headers['content-type']
    assert 'prefers-reduced-motion' in styles.text
    for name in ('wearer', 'table', 'desk', 'hall', 'together'):
        response = client.get(f'/assets/walkthrough/{name}.jpg')
        assert response.status_code == 200
        assert response.headers['content-type'] == 'image/jpeg'
        assert response.content.startswith(b'\xff\xd8')
        assert response.headers['x-content-type-options'] == 'nosniff'
    assert client.get('/assets/walkthrough/backend.env').status_code == 404


def test_dashboard_links_to_walkthrough():
    client = TestClient(app)
    response = client.get("/dashboard")
    assert response.status_code == 200
    assert 'href="/walkthrough"' in response.text


def test_walkthrough_fog_and_fall_payloads_accepted():
    token = issue_token("test-wearer", "device_writer", "hackathon-demo")
    client = TestClient(app)
    headers = {"Authorization": f"Bearer {token}"}

    # 1. FoG payload matching walkthrough.js
    res_fog = client.post("/api/v1/events/fog", headers=headers, json={
        "event_uuid": "sim-fog-test-1",
        "timestamp_utc": "2026-10-31T21:10:00Z",
        "duration_sec": 5.0,
        "peak_freeze_index": 3.42,
        "locomotor_band_power": 0.08,
        "freeze_band_power": 0.27,
        "sampled_hz": 50.0,
        "arming_mode": "walking",
        "cue_bpm": 100,
        "recovery_latency_sec": 2.5
    })
    assert res_fog.status_code == 200
    assert res_fog.json()["status"] == "logged"

    # 2. Reality-check payload matching walkthrough.js
    res_rc = client.post("/api/v1/reality-check", headers=headers, json={
        "event_uuid": "sim-rc-test-1",
        "timestamp_utc": "2026-10-31T21:10:00Z",
        "user_query": "Is someone by the door?",
        "simulated_sam_masks": [{"label": "coat rack", "confidence": 0.94, "area_ratio": 0.24}]
    })
    assert res_rc.status_code == 200
    assert "spoken_response" in res_rc.json()
