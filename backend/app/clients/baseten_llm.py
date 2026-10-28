from typing import Any, Dict, List, Optional
import httpx

from app.clients.circuit_breaker import RequestDeadlineContext, circuit_breakers
from app.config import settings
from app.services.plain_language import summarize_day


class BasetenLLMClient:
    """
    Baseten 2M-TPM client ($100 Credits) running meta-models/muse-spark-open-1026.
    Used for:
      1. Selecting a template_id + 1 inanimate label strictly from L_sam in Reality Check.
      2. Writing the plain day summary for the report.
    """

    PROVIDER = "baseten"

    async def choose_reality_check_slot(
        self,
        user_query: str,
        allowed_inanimate_labels: List[str],
        deadline: RequestDeadlineContext,
    ) -> Optional[Dict[str, str]]:
        """
        Asks Baseten muse-spark-open-1026 to pick one label from allowed_inanimate_labels.
        Returns {"template_id": str, "chosen_label": str} or None on timeout/breaker.
        """
        model_id = settings.baseten_model
        if not allowed_inanimate_labels:
            return None
        if not circuit_breakers.is_available(self.PROVIDER, model_id):
            return None
        if not settings.baseten_api_key:
            return None

        try:
            timeout_sec = deadline.timeout_for_stage(settings.baseten_stage_budget_sec)
            async with httpx.AsyncClient(timeout=timeout_sec) as client:
                resp = await client.post(
                    f"{settings.baseten_api_base_url.rstrip('/')}/chat/completions",
                    headers={"Authorization": f"Bearer {settings.baseten_api_key}"},
                    json={
                        "model": model_id,
                        "temperature": 0.0,
                        "max_tokens": 40,
                        "messages": [
                            {
                                "role": "system",
                                "content": (
                                    "Select the single most relevant inanimate label from the "
                                    f"verified set {allowed_inanimate_labels}. Reply ONLY with the label."
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
    ) -> str:
        """
        Plain counts of the day's events and the latest raw task measurements.
        Deterministic, so the report always has wording that names no medication
        state and no score.
        """
        return summarize_day(summary_stats)


baseten_client = BasetenLLMClient()
