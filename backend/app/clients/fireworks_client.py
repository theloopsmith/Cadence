from typing import Any, Dict, List, Optional
import httpx

from app.clients.circuit_breaker import RequestDeadlineContext, circuit_breakers
from app.config import settings
from app.services.plain_language import is_plain, summarize_day


class FireworksClient:
    """
    Fireworks AI client ($100 Credits) providing ultra-fast inference for:
      - Meta Llama 3.3 70B Instruct (accounts/fireworks/models/llama-v3p3-70b-instruct)
      - Meta Llama 3.2 11B Vision (accounts/fireworks/models/llama-v3p2-11b-vision-instruct)
    Features 3-strike circuit breaker isolation and bounded deadline enforcement.
    """

    PROVIDER = "fireworks"

    async def choose_reality_check_slot(
        self,
        user_query: str,
        allowed_inanimate_labels: List[str],
        deadline: RequestDeadlineContext,
    ) -> Optional[Dict[str, str]]:
        """
        Asks Llama 3.3 70B to pick one inanimate label from allowed_inanimate_labels.
        Returns {"template_id": str, "chosen_label": str} or None on timeout/breaker.
        """
        model_id = settings.fireworks_llm_model
        if not allowed_inanimate_labels:
            return None
        if not circuit_breakers.is_available(self.PROVIDER, model_id):
            return None
        if not settings.fireworks_api_key:
            return None

        try:
            timeout_sec = deadline.timeout_for_stage(settings.fireworks_stage_budget_sec)
            async with httpx.AsyncClient(timeout=timeout_sec) as client:
                resp = await client.post(
                    f"{settings.fireworks_api_base_url.rstrip('/')}/chat/completions",
                    headers={"Authorization": f"Bearer {settings.fireworks_api_key}"},
                    json={
                        "model": model_id,
                        "temperature": 0.0,
                        "max_tokens": 40,
                        "messages": [
                            {
                                "role": "system",
                                "content": (
                                    "Select the single most relevant inanimate label from the "
                                    f"verified set {allowed_inanimate_labels}. Reply ONLY with the label name."
                                ),
                            },
                            {"role": "user", "content": user_query},
                        ],
                    },
                )
                resp.raise_for_status()
                content = (
                    resp.json()["choices"][0]["message"]["content"].strip().lower()
                )
                circuit_breakers.record_success(self.PROVIDER, model_id)
                for candidate in allowed_inanimate_labels:
                    if candidate.lower() in content:
                        from app.services.reality_check import (
                            UPRIGHT_FIXTURE_LABELS,
                        )

                        tpl = (
                            "REASSURE_SHADOW_OR_LIGHT"
                            if candidate.lower() in UPRIGHT_FIXTURE_LABELS
                            else "REASSURE_OBJECT_ON_SEAT"
                        )
                        return {"template_id": tpl, "chosen_label": candidate.lower()}
                return None
        except Exception:
            circuit_breakers.record_failure(self.PROVIDER, model_id)
            return None

    async def summarize_clinical_diary(
        self,
        summary_stats: Dict[str, Any],
        deadline: Optional[RequestDeadlineContext] = None,
    ) -> Optional[str]:
        """
        Rephrases the plain day summary with Llama 3.3 70B. Only the plain facts
        are sent, and the reply is rejected unless it stays plain. Returns None on
        failure, if unconfigured, or if the reply drifts into clinical language.
        """
        model_id = settings.fireworks_llm_model
        if not settings.fireworks_api_key:
            return None
        if not circuit_breakers.is_available(self.PROVIDER, model_id):
            return None

        facts = summarize_day(summary_stats)
        prompt = (
            "Rewrite these facts as two or three short, warm sentences for the person and their care team. "
            "Keep every number exactly as given. Add nothing.\n\n" + facts
        )

        try:
            timeout_sec = (
                deadline.timeout_for_stage(settings.fireworks_stage_budget_sec)
                if deadline
                else settings.fireworks_stage_budget_sec
            )
            async with httpx.AsyncClient(timeout=timeout_sec) as client:
                resp = await client.post(
                    f"{settings.fireworks_api_base_url.rstrip('/')}/chat/completions",
                    headers={"Authorization": f"Bearer {settings.fireworks_api_key}"},
                    json={
                        "model": model_id,
                        "temperature": 0.2,
                        "max_tokens": 120,
                        "messages": [
                            {
                                "role": "system",
                                "content": (
                                    "You describe a day's logged events in plain, reassuring language. "
                                    "Never name medication states, never give scores, never interpret "
                                    "health or give advice about medication."
                                ),
                            },
                            {"role": "user", "content": prompt},
                        ],
                    },
                )
                resp.raise_for_status()
                text = resp.json()["choices"][0]["message"]["content"].strip()
                circuit_breakers.record_success(self.PROVIDER, model_id)
                return text if is_plain(text) else None
        except Exception:
            circuit_breakers.record_failure(self.PROVIDER, model_id)
            return None


fireworks_client = FireworksClient()
