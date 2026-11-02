import asyncio
import json
import io
from PIL import Image
from unittest.mock import AsyncMock

import httpx
import pytest
from app.config import settings
from app.clients.baseten_llm import baseten_client
from app.clients.circuit_breaker import RequestDeadlineContext, circuit_breakers
from app.clients.meta_models import meta_client
from app.services.reality_check import run_reality_check_pipeline, INANIMATE_VOCAB


def photo():
    output=io.BytesIO(); Image.new('RGB',(8,8),'white').save(output,format='JPEG'); return output.getvalue()


def test_general_question_discovers_sofa_but_requires_sam_grounding(monkeypatch):
    discovery = AsyncMock(return_value={"labels": ["sofa", "table"], "source": "meta_open_weights", "model": settings.baseten_model, "provider": "baseten"})
    monkeypatch.setattr(settings,"baseten_api_key","fixture")
    seen = []
    async def sam(**kwargs):
        seen.extend(kwargs['candidate_labels'])
        return {"sam_verified": True, "model": settings.meta_sam_model, "masks": [{"label":"sofa", "confidence":.9, "area_ratio":.2}] if "sofa" in kwargs["candidate_labels"] else []}
    monkeypatch.setattr(baseten_client, 'propose_scene_labels', discovery)
    monkeypatch.setattr(meta_client, 'segment_sam_3_1', sam)
    monkeypatch.setattr(baseten_client, 'choose_reality_check_slot', AsyncMock(return_value=None))
    result = asyncio.run(run_reality_check_pipeline("What am I looking at?", b'photo'))
    assert 'sofa' in seen and 'person' in seen and len(seen) <= 6
    assert result['analysis_status'] == 'identified'
    assert result['chosen_inanimate_label'] == 'sofa'
    assert result['model_evidence']['proposal']['model'] == settings.baseten_model
    # Vision's table proposal alone cannot appear as an observed object.
    assert 'table' not in [m['label'] for m in result['verified_masks']]


def test_named_question_skips_discovery_and_simulation_never_uploads_media(monkeypatch):
    async def forbidden(*args, **kwargs): raise AssertionError('must not invoke discovery')
    monkeypatch.setattr(baseten_client, 'propose_scene_labels', forbidden)
    async def empty(**kwargs): return {"sam_verified":True, "masks":[]}
    monkeypatch.setattr(meta_client, 'segment_sam_3_1', empty)
    asyncio.run(run_reality_check_pipeline('Where is the lamp?', b'photo'))
    asyncio.run(run_reality_check_pipeline('Describe the room', b'photo', simulated_sam_masks=[]))


def test_provider_failure_is_not_reported_as_darkness_or_no_objects(monkeypatch):
    monkeypatch.setattr(meta_client, 'segment_sam_3_1', AsyncMock(return_value={"sam_verified": False, "masks": [], "reason":"unconfigured_or_empty"}))
    result = asyncio.run(run_reality_check_pipeline('Is anyone there?', None))
    assert result['analysis_status'] == 'unavailable'
    assert 'service' in result['spoken_response']
    assert 'light' not in result['spoken_response']
    assert 'clear objects' not in result['spoken_response']


def test_partial_sam_failure_keeps_a_grounded_object_without_certifying_scene(monkeypatch):
    monkeypatch.setattr(meta_client, 'segment_sam_3_1', AsyncMock(return_value={
        'sam_verified':False, 'model':settings.meta_sam_model, 'failed_labels':['person'],
        'masks':[{'label':'lamp','confidence':.9,'area_ratio':.2}]}))
    monkeypatch.setattr(baseten_client, 'choose_reality_check_slot', AsyncMock(return_value=None))
    result = asyncio.run(run_reality_check_pipeline('Check the lamp', None))
    assert result['analysis_status'] == 'partial' and result['sam_verified'] is False
    assert result['chosen_inanimate_label'] == 'lamp'
    assert 'cannot confirm' in result['spoken_response']


@pytest.mark.parametrize('answer', ['["sofa"]', '["invented object"]', 'Here is a sofa', '{"label":"sofa"}', '["sofa", "table", "lamp", "bed"]'])
def test_discovery_uses_image_parts_and_rejects_any_unallowed_output(monkeypatch, answer):
    circuit_breakers.reset_all()
    monkeypatch.setattr(settings,'baseten_api_key','test-only')
    captured = []
    async def post(self, url, **kwargs):
        captured.append(kwargs['json'])
        return httpx.Response(200, request=httpx.Request('POST',url), json={'choices':[{'message':{'content':answer}}]})
    monkeypatch.setattr(httpx.AsyncClient,'post',post)
    result = asyncio.run(baseten_client.propose_scene_labels(photo(), sorted(INANIMATE_VOCAB), RequestDeadlineContext()))
    parts = captured[0]['messages'][1]['content']
    assert parts[1]['image_url']['url'].startswith('data:image/jpeg;base64,')
    assert captured[0]['model'] == settings.baseten_model
    assert (result is not None) == (answer == '["sofa"]')


def test_discovery_has_a_real_wall_clock_limit(monkeypatch):
    circuit_breakers.reset_all()
    monkeypatch.setattr(settings,'baseten_api_key','test-only')
    monkeypatch.setattr(settings,'scene_proposal_budget_sec',.02)
    async def never(*args,**kwargs): await asyncio.sleep(10)
    monkeypatch.setattr(httpx.AsyncClient,'post',never)
    assert asyncio.run(baseten_client.propose_scene_labels(photo(),sorted(INANIMATE_VOCAB),RequestDeadlineContext())) is None


def test_cancelled_photo_request_closes_every_sam_worker(monkeypatch):
    circuit_breakers.reset_all()
    monkeypatch.setattr(settings,'meta_api_key','fixture')
    async def run():
        entered = asyncio.Event(); cancelled = []
        async def segment(label,*args):
            entered.set()
            try: await asyncio.sleep(10)
            finally: cancelled.append(label)
        monkeypatch.setattr(meta_client,'_segment_one',segment)
        task = asyncio.create_task(meta_client.segment_sam_3_1(photo(), ['person','sofa'], RequestDeadlineContext()))
        await entered.wait(); task.cancel()
        with pytest.raises(asyncio.CancelledError): await task
        assert set(cancelled) == {'person','sofa'}
    asyncio.run(run())
