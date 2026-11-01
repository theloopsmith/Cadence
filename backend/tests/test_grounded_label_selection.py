"""The Muse selector returns one exact SAM-grounded label, never a substring."""
from unittest.mock import AsyncMock, Mock
import pytest
from app.clients.baseten_llm import BasetenLLMClient
from app.clients.circuit_breaker import RequestDeadlineContext, circuit_breakers
from app.config import settings


@pytest.mark.asyncio
@pytest.mark.parametrize('answer,expected', [
    ('coat rack', 'coat rack'), ('"COAT"', 'coat'),
    ('not a coat; maybe a chair', None), ('a coat rack near the door', None),
    ('unknown object', None), ('', None),
])
async def test_selector_requires_one_complete_grounded_label(monkeypatch, answer, expected):
    monkeypatch.setattr(settings, 'baseten_api_key', 'fixture-only')
    circuit_breakers.record_success('baseten', settings.baseten_model)
    response = Mock()
    response.json.return_value = {'choices':[{'message':{'content':answer}}]}
    client = AsyncMock(); client.post.return_value = response
    context = AsyncMock(); context.__aenter__.return_value = client
    monkeypatch.setattr('app.clients.baseten_llm.httpx.AsyncClient', Mock(return_value=context))
    result = await BasetenLLMClient().choose_reality_check_slot('What is by the door?', ['coat','coat rack','chair'], RequestDeadlineContext())
    assert (result['chosen_label'] if result else None) == expected
    if result:
        assert result['model'] == settings.baseten_model
        assert result['provider'] == 'baseten'
        assert result['latency_ms'] >= 0
    sent = client.post.call_args.kwargs['json']
    assert sent['model'] == 'meta-models/muse-spark-open-1026'
    assert sent['reasoning_effort'] == 'low'
    assert sent['max_tokens'] >= 512


@pytest.mark.asyncio
async def test_selection_has_a_wall_clock_bound_even_if_transport_never_returns(monkeypatch):
    import asyncio
    monkeypatch.setattr(settings, 'baseten_api_key', 'fixture-only')
    monkeypatch.setattr(settings, 'baseten_stage_budget_sec', 0.01)
    circuit_breakers.record_success('baseten', settings.baseten_model)
    async def hang(*args, **kwargs):
        await asyncio.Event().wait()
    client = AsyncMock(); client.post.side_effect = hang
    context = AsyncMock(); context.__aenter__.return_value = client
    monkeypatch.setattr('app.clients.baseten_llm.httpx.AsyncClient', Mock(return_value=context))
    result = await asyncio.wait_for(BasetenLLMClient().choose_reality_check_slot(
        'What is by the door?', ['coat'], RequestDeadlineContext()), timeout=1)
    assert result is None
    client.post.assert_awaited_once()
