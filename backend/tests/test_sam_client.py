"""A live SAM call has to carry the camera frame, and pixel areas have to come back as frame fractions."""

import base64
from io import BytesIO

import pytest
from PIL import Image

from app.clients.circuit_breaker import RequestDeadlineContext, circuit_breakers
from app.clients.meta_models import MetaModelClient
from app.config import settings


def _jpeg(width: int, height: int) -> bytes:
    buffer = BytesIO()
    Image.new("RGB", (width, height), "white").save(buffer, format="JPEG")
    return buffer.getvalue()


class _Response:
    def __init__(self, payload):
        self._payload = payload

    def raise_for_status(self):
        return None

    def json(self):
        return self._payload


class _CaptureClient:
    posts = []

    def __init__(self, timeout):
        self.timeout = timeout

    async def __aenter__(self):
        return self

    async def __aexit__(self, exc_type, exc, tb):
        return None

    async def post(self, url, headers, json):
        self.posts.append({"url": url, "json": json})
        return _Response(
            {
                "masks": [
                    {"label": "coat", "confidence": 0.91, "area_px": 200},
                ]
            }
        )


@pytest.fixture
def capture(monkeypatch):
    _CaptureClient.posts = []
    monkeypatch.setattr(settings, "meta_api_key", "test-key")
    monkeypatch.setattr("app.clients.meta_models.httpx.AsyncClient", _CaptureClient)
    circuit_breakers.record_success("meta", settings.meta_sam_model)
    return _CaptureClient


@pytest.mark.asyncio
async def test_segmentation_sends_the_frame_and_reports_area_as_a_fraction(capture):
    jpeg = _jpeg(100, 100)
    result = await MetaModelClient().segment_sam_3_1(
        image_bytes=jpeg,
        candidate_labels=["coat", "person"],
        deadline=RequestDeadlineContext(),
    )

    assert len(capture.posts) == 1
    body = capture.posts[0]["json"]
    assert base64.b64decode(body["image_base64"]) == jpeg
    assert body["candidate_labels"] == ["coat", "person"]
    assert result["sam_verified"] is True
    # 200 px on a 100x100 frame is 2% of the image, above the 1.5% reality-check floor.
    assert result["masks"][0]["area_ratio"] == pytest.approx(0.02)
