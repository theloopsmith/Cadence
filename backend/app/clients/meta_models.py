import json
import base64
from io import BytesIO
from typing import Any, Dict, List, Optional

import httpx
from PIL import Image

from app.clients.circuit_breaker import RequestDeadlineContext, circuit_breakers
from app.config import settings


def _frame_pixel_count(image_bytes: bytes) -> int:
    try:
        with Image.open(BytesIO(image_bytes)) as frame:
            width, height = frame.size
    except Exception:
        return 0
    if width <= 0 or height <= 0:
        return 0
    return width * height


def masks_with_frame_fraction(
    masks: List[Dict[str, Any]], image_bytes: bytes
) -> List[Dict[str, Any]]:
    """SAM reports absolute pixels. The rest of the pipeline filters on frame fraction."""
    frame_pixels = _frame_pixel_count(image_bytes)
    normalized: List[Dict[str, Any]] = []
    for mask in masks:
        copied = dict(mask)
        if "area_ratio" not in copied and frame_pixels and copied.get("area_px") is not None:
            copied["area_ratio"] = float(copied["area_px"]) / frame_pixels
        normalized.append(copied)
    return normalized


class MetaModelClient:
    """
    Meta Model API client ($150 Credits) with per-model 3-strike circuit breakers:
      - ("meta", settings.meta_sam_model)       -> SAM 3.1 instance masks & boxes
      - ("meta", settings.meta_stt_model)       -> Muse Voice Transcribe (speech to text)
    Meta offers no text-to-speech API; spoken replies use the phone's own voices.
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
                        "image_base64": base64.b64encode(image_bytes).decode("ascii"),
                    },
                )
                resp.raise_for_status()
                data = resp.json()
                circuit_breakers.record_success(self.PROVIDER, model_id)
                return {
                    "sam_verified": True,
                    "masks": masks_with_frame_fraction(data.get("masks", []), image_bytes),
                }
        except Exception as exc:
            circuit_breakers.record_failure(self.PROVIDER, model_id)
            return {"sam_verified": False, "masks": [], "reason": str(exc)}

    async def transcribe_muse_voice(
        self,
        wav_bytes: bytes,
        keywords: List[str],
        timeout_sec: float = 6.0,
    ) -> Dict[str, Any]:
        """
        Muse Voice Transcribe, one-request form (POST /asr/transcribe, multipart
        `request` JSON + `audio` WAV). Plain-text replies avoid depending on the
        JSON response shape. Returns {"available": bool, "transcript": str}.
        """
        model_id = settings.meta_stt_model
        if not circuit_breakers.is_available(self.PROVIDER, model_id):
            return {"available": False, "transcript": "", "reason": "circuit_open"}
        if not settings.meta_api_key:
            return {"available": False, "transcript": "", "reason": "unconfigured"}

        request = {
            "model": model_id,
            "audioEncoding": "WAV",
            "mode": "PUSH_TO_TALK",
            "keywords": keywords,
            "languageBias": ["english"],
        }
        try:
            async with httpx.AsyncClient(timeout=timeout_sec) as client:
                resp = await client.post(
                    f"{settings.meta_asr_base_url.rstrip('/')}/asr/transcribe",
                    headers={
                        "Authorization": f"Bearer {settings.meta_api_key}",
                        "Accept": "text/plain",
                    },
                    files={
                        "request": (None, json.dumps(request), "application/json"),
                        "audio": ("clip.wav", wav_bytes, "audio/wav"),
                    },
                )
                resp.raise_for_status()
                transcript = " ".join(line.strip() for line in resp.text.splitlines() if line.strip())
                circuit_breakers.record_success(self.PROVIDER, model_id)
                return {"available": True, "transcript": transcript}
        except Exception as exc:
            circuit_breakers.record_failure(self.PROVIDER, model_id)
            return {"available": False, "transcript": "", "reason": str(exc)}


def check_in_keywords() -> List[str]:
    """Words the fall check-in listens for, so a soft voice is more likely to be understood."""
    return ["I'm okay", "I am okay", "I'm fine", "okay", "help", "hurt", "fell", "can't get up", "emergency", "no"]


def dose_keywords(medication_name: str = "") -> List[str]:
    words = ["taken", "took", "yes", "no", "not yet", "Levodopa", "Carbidopa"]
    if medication_name and medication_name not in words:
        words.append(medication_name)
    return words


meta_client = MetaModelClient()
