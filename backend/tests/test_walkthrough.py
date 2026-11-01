"""Test interactive smart glasses walkthrough routes and asset delivery."""
from starlette.testclient import TestClient
from app.main import app


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
    assert "STORAGE_KEY" in response.text
    assert "apiCall" in response.text


def test_dashboard_links_to_walkthrough():
    client = TestClient(app)
    response = client.get("/dashboard")
    assert response.status_code == 200
    assert 'href="/walkthrough"' in response.text
