"""Bad input is refused at the door with a 422, never stored as garbage or turned
into a 500 the phone retries forever."""

from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient

from app.config import settings
from app.main import app

DEVICE = {"Authorization": f"Bearer {settings.cadence_device_token}"}


@pytest.fixture
def client():
    with TestClient(app) as c:
        yield c


def _fog(**overrides):
    body = {
        "event_uuid": "fog-validation-0001",
        "duration_sec": 2.0,
        "peak_freeze_index": 3.0,
        "locomotor_band_power": 1.0,
        "freeze_band_power": 3.0,
    }
    body.update(overrides)
    return body


def test_nan_and_infinity_are_rejected_not_stored(client):
    # Python's JSON parser accepts these literals; the API must not.
    for literal in ("NaN", "Infinity", "-Infinity"):
        raw = '{"event_uuid":"fog-nan-0001","duration_sec":%s,"peak_freeze_index":1,"locomotor_band_power":1,"freeze_band_power":1}' % literal
        res = client.post("/api/v1/events/fog", headers={**DEVICE, "Content-Type": "application/json"}, content=raw)
        assert res.status_code == 422, (literal, res.text)


def test_unparseable_timestamp_is_rejected(client):
    res = client.post("/api/v1/events/fog", headers=DEVICE, json=_fog(timestamp_utc="not a time"))
    assert res.status_code == 422


def test_far_future_timestamp_is_rejected(client):
    future = (datetime.now(timezone.utc) + timedelta(days=2)).isoformat()
    res = client.post("/api/v1/events/fog", headers=DEVICE, json=_fog(timestamp_utc=future))
    assert res.status_code == 422


def test_timestamps_without_a_zone_are_treated_as_utc(client):
    naive = datetime.now(timezone.utc).replace(tzinfo=None).isoformat(timespec="seconds")
    res = client.post("/api/v1/events/fog", headers=DEVICE, json=_fog(event_uuid="fog-naive-0001", timestamp_utc=naive))
    assert res.status_code == 200, res.text


def test_a_trailing_z_is_accepted(client):
    stamped = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    res = client.post("/api/v1/events/fog", headers=DEVICE, json=_fog(event_uuid="fog-zulu-0001", timestamp_utc=stamped))
    assert res.status_code == 200, res.text


def test_coordinates_outside_the_globe_are_rejected(client):
    body = {"event_uuid": "fall-coords-0001", "status": "confirmed_waiting_dispatch",
            "peak_impact_g": 3.0, "peak_jerk_gs": 40.0, "post_impact_tilt_deg": 60.0,
            "latitude": 123.0, "longitude": 0.0}
    res = client.post("/api/v1/events/fall", headers=DEVICE, json=body)
    assert res.status_code == 422


def test_oversized_text_and_image_fields_are_rejected_before_parsing_work(client):
    res = client.post("/api/v1/reality-check", headers=DEVICE,
                      json={"event_uuid": "rc-long-0001", "user_query": "x" * 2000})
    assert res.status_code == 422
    res = client.post("/api/v1/reality-check", headers=DEVICE,
                      json={"event_uuid": "rc-img-0001", "user_query": "Is anyone there?",
                            "image_base64": "A" * (10 * 1024 * 1024 + 1)})
    assert res.status_code in (413, 422)
