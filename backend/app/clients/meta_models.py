from typing import Any, Dict, List, Optional
import httpx

from app.clients.circuit_breaker import RequestDeadlineContext, circuit_breakers
from app.config import settings


class MetaModelClient:
    """
    Meta Model API client ($150 Credits) with per-model 3-strike circuit breakers:
      - ("meta", settings.meta_sam_model)       -> SAM 3.1 instance masks & boxes
      - ("meta", settings.meta_stt_model)       -> Muse Transcribe STT
      - ("meta", settings.meta_tts_model)       -> Muse Voice TTS
    """

    PROVIDER = "meta"

    async def segment_sam_3_1(
        self,
        image_bytes: Optional[bytes],
        candidate_labels: List[str],
        deadline: RequestDeadlineContext,
        simulated_masks: Optional[List[Dict[str, Any]]] = None,
    ) -> Dict[str, Any]:
        """
        Runs SAM 3.1 segmentation within the shared 4.0s deadline (1.8s stage cap).
        Returns {"sam_verified": bool, "masks": List[dict]}.
        """
        model_id = settings.meta_sam_model
        if not circuit_breakers.is_available(self.PROVIDER, model_id):
            return {"sam_verified": False, "masks": [], "reason": "circuit_open"}

        if simulated_masks is not None:
            circuit_breakers.record_success(self.PROVIDER, model_id)
            return {"sam_verified": True, "masks": simulated_masks}

        if not settings.meta_api_key or not image_bytes:
            return {"sam_verified": False, "masks": [], "reason": "unconfigured_or_empty"}

        try:
            timeout_sec = deadline.timeout_for_stage(settings.sam_stage_budget_sec)
            async with httpx.AsyncClient(timeout=timeout_sec) as client:
                resp = await client.post(
                    f"{settings.meta_api_base_url.rstrip('/')}/vision/segment",
                    headers={"Authorization": f"Bearer {settings.meta_api_key}"},
                    json={
                        "model": model_id,
                        "candidate_labels": candidate_labels,
                    },
                )
                resp.raise_for_status()
                data = resp.json()
                circuit_breakers.record_success(self.PROVIDER, model_id)
                return {"sam_verified": True, "masks": data.get("masks", [])}
        except Exception as exc:
            circuit_breakers.record_failure(self.PROVIDER, model_id)
            return {"sam_verified": False, "masks": [], "reason": str(exc)}

    async def synthesize_muse_voice(
        self,
        text: str,
        deadline: RequestDeadlineContext,
    ) -> Dict[str, Any]:
        """
        Synthesizes calm open-ear audio via Muse Voice (0.8s budget).
        If remaining deadline < 0.35s or breaker is open, returns text immediately
        for zero-latency on-device AVSpeechSynthesizer fallback.
        """
        model_id = settings.meta_tts_model
        if not circuit_breakers.is_available(self.PROVIDER, model_id):
            return {"tts_source": "ios_avspeech_fallback", "audio_base64": None, "text": text}

        if not settings.meta_api_key:
            return {"tts_source": "ios_avspeech_fallback", "audio_base64": None, "text": text}

        try:
            timeout_sec = deadline.timeout_for_stage(
                settings.tts_stage_budget_sec, min_viable_sec=0.35
            )
            async with httpx.AsyncClient(timeout=timeout_sec) as client:
                resp = await client.post(
                    f"{settings.meta_api_base_url.rstrip('/')}/audio/speech",
                    headers={"Authorization": f"Bearer {settings.meta_api_key}"},
                    json={"model": model_id, "input": text},
                )
                resp.raise_for_status()
                data = resp.json()
                circuit_breakers.record_success(self.PROVIDER, model_id)
                return {
                    "tts_source": "meta_muse_voice",
                    "audio_base64": data.get("audio_base64"),
                    "text": text,
                }
        except Exception:
            circuit_breakers.record_failure(self.PROVIDER, model_id)
            return {"tts_source": "ios_avspeech_fallback", "audio_base64": None, "text": text}


meta_client = MetaModelClient()
