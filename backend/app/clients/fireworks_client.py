from typing import Any, Dict, List, Optional
import httpx

from app.clients.circuit_breaker import RequestDeadlineContext, circuit_breakers
from app.config import settings


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
        Uses Llama 3.3 70B on Fireworks to generate an objective clinical summary
        narrative for the neurologist report. Returns None on failure or if unconfigured.
        """
        model_id = settings.fireworks_llm_model
        if not settings.fireworks_api_key:
            return None
        if not circuit_breakers.is_available(self.PROVIDER, model_id):
            return None

        on_pct = summary_stats.get("on_pct", 0.0)
        wearing_off_pct = summary_stats.get("wearing_off_pct", 0.0)
        off_pct = summary_stats.get("off_pct", 0.0)
        fog_total = summary_stats.get("fog_count", 0)
        fall_total = summary_stats.get("fall_count", 0)
        resolved_falls = summary_stats.get("fall_candidate_resolved_count", 0)
        latest_exam = summary_stats.get("latest_exam_score")
        delta = summary_stats.get("exam_on_vs_off_delta")

        prompt = (
            f"Generate a concise, 2-3 sentence objective clinical report for a movement disorders neurologist:\n"
            f"- 24h Motor States: ON: {on_pct:.0f}%, WEARING_OFF: {wearing_off_pct:.0f}%, OFF: {off_pct:.0f}%\n"
            f"- Freezing of Gait (FoG) Episodes: {fog_total}\n"
            f"- Falls: {fall_total} confirmed, {resolved_falls} resolved by voice check-in\n"
        )
        if latest_exam is not None:
            prompt += f"- Latest 3-step home motor exam composite score: {latest_exam:.1f}/100\n"
        if delta:
            prompt += (
                f"- Levodopa response: {delta.get('off_baseline_state', 'OFF')} composite {float(delta['off_composite']):.1f} "
                f"-> ON composite {float(delta['on_composite']):.1f} (change: {float(delta['composite_improvement_pts']):+.1f} pts)\n"
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
                                    "You are an objective Parkinson's clinical decision support AI assistant. "
                                    "Provide a precise, factual summary strictly derived from the provided numbers. "
                                    "Do not extrapolate or give advice."
                                ),
                            },
                            {"role": "user", "content": prompt},
                        ],
                    },
                )
                resp.raise_for_status()
                text = resp.json()["choices"][0]["message"]["content"].strip()
                circuit_breakers.record_success(self.PROVIDER, model_id)
                return text
        except Exception:
            circuit_breakers.record_failure(self.PROVIDER, model_id)
            return None


fireworks_client = FireworksClient()
