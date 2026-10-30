from uuid import UUID
import pytest
from fastapi.testclient import TestClient
from app.config import settings
from app.db import init_db_sync
from app.main import app


@pytest.fixture
def http(monkeypatch, tmp_path):
    monkeypatch.setattr(settings, 'sqlite_db_path', str(tmp_path / 'connection.db'))
    init_db_sync()
    return TestClient(app)


def test_connection_identity_requires_phone_authorization(http):
    assert http.get('/api/v1/device/connection').status_code == 401
    assert http.get('/api/v1/device/connection', headers={'Authorization': f'Bearer {settings.cadence_clinician_token}'}).status_code == 403
    response = http.get('/api/v1/device/connection', headers={'Authorization': f'Bearer {settings.cadence_device_token}'})
    assert response.status_code == 200
    body = response.json()
    UUID(body['server_id'])
    assert body['patient_id'] == settings.cadence_default_patient_id
    assert set(body) == {'service', 'server_id', 'patient_id'}


def test_identity_is_stable_across_database_upgrade_and_distinct_per_database(http, monkeypatch, tmp_path):
    headers = {'Authorization': f'Bearer {settings.cadence_device_token}'}
    first = http.get('/api/v1/device/connection', headers=headers).json()['server_id']
    init_db_sync()
    assert http.get('/api/v1/device/connection', headers=headers).json()['server_id'] == first
    monkeypatch.setattr(settings, 'sqlite_db_path', str(tmp_path / 'other.db'))
    init_db_sync()
    assert http.get('/api/v1/device/connection', headers=headers).json()['server_id'] != first
