import json
from unittest.mock import AsyncMock, Mock
import pytest
from fastapi.testclient import TestClient
from app.main import app
from app.config import settings
from app.services import companion


def test_conversation_requires_device_account_and_limits_input():
    client = TestClient(app)
    assert client.post('/api/v1/companion/interpret', json={'text':'help'}).status_code == 401
    headers = {'Authorization': 'Bearer ' + settings.cadence_device_token}
    result = client.post('/api/v1/companion/interpret', headers=headers, json={'text':'help'})
    assert result.status_code == 200
    assert result.json() == {'intent':'unknown', 'source':'local_fallback'}
    assert client.post('/api/v1/companion/interpret', headers=headers, json={'text':'x'*1201}).status_code == 422
    assert client.post('/api/v1/companion/interpret', headers=headers, json={'text':'help','history':['x']*7}).status_code == 422
    assert client.post('/api/v1/companion/interpret', headers=headers, json={'text':'help','history':['x'*1201]}).status_code == 422


@pytest.mark.asyncio
@pytest.mark.parametrize('content, expected', [('motor','motor'), ('execute_sql','unknown')])
async def test_meta_intent_is_allowlisted_and_never_executes_actions(monkeypatch, content, expected):
    monkeypatch.setattr(settings, 'fireworks_api_key', 'fixture-key')
    monkeypatch.setattr(settings, 'fireworks_llm_model', 'meta-llama-fixture-' + content)
    response = Mock()
    response.json.return_value = {'choices':[{'message':{'content': json.dumps({'intent':content})}}]}
    client = AsyncMock(); client.post.return_value = response
    context = AsyncMock(); context.__aenter__.return_value = client
    monkeypatch.setattr(companion.httpx, 'AsyncClient', Mock(return_value=context))
    result = await companion.interpret('Could we check how I am moving?', ['assistant: What would help?'])
    assert result['intent'] == expected
    sent = client.post.call_args.kwargs['json']
    assert sent['model'] == settings.fireworks_llm_model
    assert 'Plain "I need help"' in sent['messages'][0]['content']


@pytest.mark.asyncio
async def test_provider_failure_falls_back_without_inventing_an_action(monkeypatch):
    monkeypatch.setattr(settings, 'fireworks_api_key', 'fixture-key')
    monkeypatch.setattr(settings, 'fireworks_llm_model', 'meta-llama-fixture-fail')
    context = AsyncMock(); context.__aenter__.side_effect = TimeoutError()
    monkeypatch.setattr(companion.httpx, 'AsyncClient', Mock(return_value=context))
    assert await companion.interpret('help', []) == {'intent':'unknown', 'source':'local_fallback'}


@pytest.mark.asyncio
async def test_muse_open_uses_low_reasoning_with_room_for_a_final_answer(monkeypatch):
    monkeypatch.setattr(settings, 'baseten_api_key', 'fixture-key')
    monkeypatch.setattr(settings, 'baseten_model', 'meta-models/muse-spark-open-fixture')
    response = Mock()
    response.json.return_value = {'choices':[{'message':{'content':'{"intent":"motor"}'}}]}
    client = AsyncMock(); client.post.return_value = response
    context = AsyncMock(); context.__aenter__.return_value = client
    monkeypatch.setattr(companion.httpx, 'AsyncClient', Mock(return_value=context))
    result = await companion.interpret('Could we check my movement?', [])
    assert result['intent'] == 'motor'
    assert result['source'] == 'meta_open_weights'
    sent = client.post.call_args.kwargs['json']
    assert sent['reasoning_effort'] == 'low'
    assert sent['max_tokens'] >= 512
