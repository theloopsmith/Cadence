"""SAM 3.1 through Meta's Responses API: one noun phrase per request, special-token
text back, a missing confidence is not zero, and an empty lane is zero matches."""

import asyncio
import base64
import json
from io import BytesIO

import pytest
from PIL import Image

from app.clients.circuit_breaker import RequestDeadlineContext, circuit_breakers
from app.clients.meta_models import MetaModelClient
from app.clients.sam_output import parse_sam_output_text, output_text_from_response
from app.config import settings


def _jpeg(width: int, height: int) -> bytes:
    buffer = BytesIO()
    Image.new("RGB", (width, height), "white").save(buffer, format="JPEG")
    return buffer.getvalue()


# A 100x80 frame. Box 10..19 x 20..29 inclusive is 10x10 = 100 px of 8000.
ONE_WITH_CONFIDENCE = "<0f>0<|box;x1=10;y1=20;x2=19;y2=29;w=100;h=80;c=0.75|><|mask;x=0;y=0;c=0.75;data=10,10,!!!!!(QO(0lu8?|>"
ONE_WITHOUT_CONFIDENCE = "<0f>0<|box;x1=10;y1=20;x2=19;y2=29;w=100;h=80|><|mask;x=0;y=0;data=10,10,!!!!!(QO(0lu8?|>"
TWO_OBJECTS = (
    "<0f>0<|box;x1=0;y1=0;x2=49;y2=79;w=100;h=80;c=0.9|><|mask;x=0;y=0;data=80,50,~abc|>"
    ",2<|box;x1=90;y1=70;x2=99;y2=79;w=100;h=80|><|mask;x=0;y=0;data=10,10,!xyz|>"
)


# ---------- Parser ----------


def test_parses_box_confidence_and_frame_fraction():
    records = parse_sam_output_text(ONE_WITH_CONFIDENCE, label="coat")
    assert len(records) == 1
    r = records[0]
    assert r["label"] == "coat"
    assert r["object_id"] == "0"
    assert r["confidence"] == pytest.approx(0.75)
    assert r["box"] == {"x1": 10, "y1": 20, "x2": 19, "y2": 29, "w": 100, "h": 80}
    assert r["area_ratio"] == pytest.approx(100 / 8000)


def test_missing_confidence_is_none_not_zero():
    records = parse_sam_output_text(ONE_WITHOUT_CONFIDENCE, label="chair")
    assert records[0]["confidence"] is None


def test_multiple_segments_with_optional_commas():
    records = parse_sam_output_text(TWO_OBJECTS, label="person")
    assert [r["object_id"] for r in records] == ["0", "2"]
    assert records[0]["area_ratio"] == pytest.approx(0.5)
    assert records[1]["confidence"] is None


def test_empty_lane_is_zero_matches():
    assert parse_sam_output_text("", label="dog") == []
    assert parse_sam_output_text("\n  \n", label="dog") == []


def test_malformed_line_is_dropped_and_good_lines_kept():
    text = "<0f>\n" + ONE_WITH_CONFIDENCE + "\n<0f>0<|box;x1=1|>"
    records = parse_sam_output_text(text, label="coat")
    assert len(records) == 1


def test_payload_text_cannot_hide_a_confidence():
    # The payload alphabet includes '=' and letters, so "c=" inside data must not be read as a field.
    text = "<0f>0<|box;x1=0;y1=0;x2=9;y2=9;w=100;h=80|><|mask;x=0;y=0;data=10,10,!c=0.99abc|>"
    assert parse_sam_output_text(text, label="lamp")[0]["confidence"] is None


def test_output_text_is_found_in_either_response_shape():
    assert output_text_from_response({"output_text": "abc"}) == "abc"
    nested = {"output": [{"type": "message", "content": [{"type": "output_text", "text": "xyz"}]}]}
    assert output_text_from_response(nested) == "xyz"
    assert output_text_from_response({"output": []}) == ""


# ---------- Client ----------


class _Response:
    def __init__(self, payload):
        self._payload = payload

    def raise_for_status(self):
        return None

    def json(self):
        return self._payload


class _CaptureClient:
    posts = []
    replies = {}
    failing = set()

    def __init__(self, timeout):
        self.timeout = timeout

    async def __aenter__(self):
        return self

    async def __aexit__(self, exc_type, exc, tb):
        return None

    slow = set()

    async def post(self, url, headers, json):
        label = json["input"][0]["content"][0]["text"]
        self.posts.append({"url": url, "headers": headers, "json": json, "label": label})
        if label in self.failing:
            raise RuntimeError("boom")
        if label in self.slow:
            await asyncio.sleep(2.0)
        return _Response({"output_text": self.replies.get(label, "")})


@pytest.fixture
def capture(monkeypatch):
    _CaptureClient.posts = []
    _CaptureClient.replies = {}
    _CaptureClient.failing = set()
    _CaptureClient.slow = set()
    monkeypatch.setattr(settings, "meta_api_key", "test-key")
    monkeypatch.setattr(settings, "meta_api_base_url", "https://api.meta.ai/v1")
    monkeypatch.setattr("app.clients.meta_models.httpx.AsyncClient", _CaptureClient)
    circuit_breakers.record_success("meta", settings.meta_sam_model)
    return _CaptureClient


def _run(coro):
    return asyncio.run(coro)


def test_one_responses_request_per_concept_with_the_frame_attached(capture):
    jpeg = _jpeg(100, 80)
    capture.replies = {"coat": ONE_WITH_CONFIDENCE, "person": ""}
    result = _run(
        MetaModelClient().segment_sam_3_1(
            image_bytes=jpeg, candidate_labels=["coat", "person"], deadline=RequestDeadlineContext()
        )
    )

    assert sorted(p["label"] for p in capture.posts) == ["coat", "person"]
    for post in capture.posts:
        assert post["url"] == "https://api.meta.ai/v1/responses"
        assert post["headers"]["Authorization"] == "Bearer test-key"
        body = post["json"]
        assert body["model"] == settings.meta_sam_model
        assert body["stream"] is False
        assert body["metadata"]["include_confidence"] == "true"
        message = body["input"][0]
        assert message["role"] == "user"
        image_part = message["content"][1]
        assert image_part["type"] == "input_image"
        prefix = "data:image/jpeg;base64,"
        assert image_part["image_url"].startswith(prefix)
        assert base64.b64decode(image_part["image_url"][len(prefix):]) == jpeg

    assert result["sam_verified"] is True
    assert result["model"] == settings.meta_sam_model
    assert [m["label"] for m in result["masks"]] == ["coat"]
    assert result["masks"][0]["area_ratio"] == pytest.approx(100 / 8000)
    assert result["failed_labels"] == []
    assert result["latency_ms"] >= 0


def test_zero_matches_everywhere_is_still_a_verified_result(capture):
    result = _run(
        MetaModelClient().segment_sam_3_1(
            image_bytes=_jpeg(10, 10), candidate_labels=["person", "dog"], deadline=RequestDeadlineContext()
        )
    )
    assert result["sam_verified"] is True
    assert result["masks"] == []


def test_a_failed_concept_means_the_scene_is_not_verified(capture):
    capture.replies = {"coat": ONE_WITH_CONFIDENCE}
    capture.failing = {"person"}
    result = _run(
        MetaModelClient().segment_sam_3_1(
            image_bytes=_jpeg(100, 80), candidate_labels=["coat", "person"], deadline=RequestDeadlineContext()
        )
    )
    # A coat was seen, but the question "is anyone there" went unanswered.
    assert result["sam_verified"] is False
    assert result["failed_labels"] == ["person"]
    assert [m["label"] for m in result["masks"]] == ["coat"]


def test_a_slow_concept_does_not_discard_the_ones_that_answered(capture, monkeypatch):
    monkeypatch.setattr(settings, "sam_stage_budget_sec", 0.3)
    capture.replies = {"coat": ONE_WITH_CONFIDENCE}
    capture.slow = {"person"}
    result = _run(
        MetaModelClient().segment_sam_3_1(
            image_bytes=_jpeg(100, 80), candidate_labels=["coat", "person"], deadline=RequestDeadlineContext()
        )
    )
    assert result["sam_verified"] is False
    assert result["failed_labels"] == ["person"]
    assert "budget" in result["errors"]["person"]
    assert [m["label"] for m in result["masks"]] == ["coat"]
    assert result["latency_ms"] < 1500  # did not wait for the slow one


def test_concept_count_is_bounded(capture):
    labels = [f"thing{i}" for i in range(20)]
    _run(
        MetaModelClient().segment_sam_3_1(
            image_bytes=_jpeg(10, 10), candidate_labels=labels, deadline=RequestDeadlineContext()
        )
    )
    assert len(capture.posts) <= 6


def test_simulated_masks_still_bypass_the_network(capture):
    result = _run(
        MetaModelClient().segment_sam_3_1(
            image_bytes=None,
            candidate_labels=["coat"],
            deadline=RequestDeadlineContext(),
            simulated_masks=[{"label": "coat", "confidence": 0.9, "area_ratio": 0.2}],
        )
    )
    assert capture.posts == []
    assert result["sam_verified"] is True
    assert result["masks"][0]["label"] == "coat"
