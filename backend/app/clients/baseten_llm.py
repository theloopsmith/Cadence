from typing import Any, Dict, List, Optional
import httpx

from app.clients.circuit_breaker import RequestDeadlineContext, circuit_breakers
from app.config import settings


class BasetenLLMClient:
    """
    Baseten 2M-TPM client ($100 Credits) running meta-models/muse-spark-open-1026.
    Used for:
      1. Selecting a template_id + 1 inanimate label strictly from L_sam in Reality Check.
      2. Generating the neurologist clinical narrative from deterministic S(t_k) & Exam deltas.
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
        Generates a concise objective clinical summary from deterministic ON/OFF diary
        and Home Motor Exam metrics. Falls back to a deterministic clinical summary
        if Baseten is unconfigured or offline.
        """
        on_pct = summary_stats.get("on_pct", 0.0)
        wearing_off_pct = summary_stats.get("wearing_off_pct", 0.0)
        off_pct = summary_stats.get("off_pct", 0.0)
        fog_total = summary_stats.get("fog_count", 0)
        fall_total = summary_stats.get("fall_count", 0)
        resolved_falls = summary_stats.get("fall_candidate_resolved_count", 0)
        latest_exam = summary_stats.get("latest_exam_score")
        delta = summary_stats.get("exam_on_vs_off_delta")

        deterministic_summary = (
            f"Objective 24h Motor Summary: ON {on_pct:.0f}%, WEARING_OFF {wearing_off_pct:.0f}%, "
            f"OFF {off_pct:.0f}%. Recorded {fog_total} freezing-of-gait episode(s) and "
            f"{fall_total} confirmed fall event(s)."
        )
        if resolved_falls:
            # A detected impact the patient waved off is still clinically
            # relevant; omitting it would hide a near-fall from the neurologist.
            deterministic_summary += (
                f" {resolved_falls} additional impact(s) were detected and resolved "
                "by the patient during the voice check-in."
            )
        if latest_exam is not None:
            deterministic_summary += (
                f" Latest Guided Home Motor Exam composite score: {latest_exam:.1f}/100."
            )
        if delta:
            deterministic_summary += (
                f" Measured levodopa response: composite "
                f"{float(delta['off_composite']):.1f} "
                f"({delta.get('off_baseline_state', 'OFF')}) to "
                f"{float(delta['on_composite']):.1f} (ON), a change of "
                f"{float(delta['composite_improvement_pts']):+.1f} points."
            )
        return deterministic_summary


baseten_client = BasetenLLMClient()
