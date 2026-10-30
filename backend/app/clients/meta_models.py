import asyncio
import base64
import json
import time
from typing import Any, Dict, List, Optional

import httpx

from app.clients.circuit_breaker import RequestDeadlineContext, circuit_breakers
from app.clients.sam_output import output_text_from_response, parse_sam_output_text
from app.config import settings


class MetaModelClient:
    """
    Meta Model API client ($150 Credits) with per-model 3-strike circuit breakers:
      - ("meta", settings.meta_sam_model)       -> SAM 3.1 instance masks & boxes
      - ("meta", settings.meta_stt_model)       -> Muse Voice Transcribe (speech to text)
    Meta offers no text-to-speech API; spoken replies use the phone's own voices.
    """

    PROVIDER = "meta"

    MAX_CONCEPTS = 6

    async def segment_sam_3_1(
        self,
        image_bytes: Optional[bytes],
        candidate_labels: List[str],
        deadline: RequestDeadlineContext,
        simulated_masks: Optional[List[Dict[str, Any]]] = None,
    ) -> Dict[str, Any]:
        """
        SAM 3.1 over Meta's Responses API (`POST {meta_api_base_url}/responses`).
        The model takes one noun phrase per request, so each label is its own
        call; they run together under the stage budget. Output is special-token
        text (see `sam_output`), decoded to boxes with frame fractions.

        `sam_verified` is true only when every concept got an answer. A photo
        where "person" went unanswered must not be described as empty.
        """
        model_id = settings.meta_sam_model
        if not circuit_breakers.is_available(self.PROVIDER, model_id):
            return {"sam_verified": False, "masks": [], "failed_labels": list(candidate_labels), "reason": "circuit_open"}

        if simulated_masks is not None:
            circuit_breakers.record_success(self.PROVIDER, model_id)
            return {"sam_verified": True, "masks": simulated_masks, "failed_labels": [], "model": "simulated"}

        if not settings.meta_api_key or not image_bytes:
            return {"sam_verified": False, "masks": [], "failed_labels": list(candidate_labels), "reason": "unconfigured_or_empty"}

        labels = list(dict.fromkeys(candidate_labels))[: self.MAX_CONCEPTS]
        try:
            timeout_sec = deadline.timeout_for_stage(settings.sam_stage_budget_sec)
        except TimeoutError as exc:
            return {"sam_verified": False, "masks": [], "failed_labels": labels, "reason": str(exc)}

        image_url = "data:image/jpeg;base64," + base64.b64encode(image_bytes).decode("ascii")
        started = time.monotonic()
        # httpx timeouts are per phase; this is the stage's real wall-clock bound.
        # Concepts that answered in time are kept even when another one hangs.
        tasks = {
            asyncio.ensure_future(self._segment_one(label, image_url, timeout_sec)): label
            for label in labels
        }
        done, pending = await asyncio.wait(tasks, timeout=timeout_sec)
        for task in pending:
            task.cancel()

        masks: List[Dict[str, Any]] = []
        failed: List[str] = []
        errors: Dict[str, str] = {}
        for label in labels:
            task = next(t for t, l in tasks.items() if l == label)
            if task in pending:
                failed.append(label)
                errors[label] = f"TimeoutError: stage budget {timeout_sec:.1f}s exhausted"
                continue
            exc = task.exception()
            if exc is not None:
                failed.append(label)
                errors[label] = self._describe(exc)
            else:
                masks.extend(task.result())

        if failed:
            circuit_breakers.record_failure(self.PROVIDER, model_id)
        else:
            circuit_breakers.record_success(self.PROVIDER, model_id)

        return {
            "sam_verified": not failed,
            "masks": masks,
            "failed_labels": failed,
            "errors": errors,
            "model": model_id,
            "concepts": labels,
            "latency_ms": int((time.monotonic() - started) * 1000),
        }

    @staticmethod
    def _describe(exc: BaseException) -> str:
        """Status and the first line of the body, for traces. No headers, so no key."""
        if isinstance(exc, httpx.HTTPStatusError):
            body = exc.response.text.strip().splitlines()
            return f"HTTP {exc.response.status_code}: {body[0][:300] if body else ''}"
        return f"{type(exc).__name__}: {str(exc)[:300]}"

    async def _segment_one(self, label: str, image_url: str, timeout_sec: float) -> List[Dict[str, Any]]:
        body = {
            "model": settings.meta_sam_model,
            "input": [
                {
                    "type": "message",
                    "role": "user",
                    "content": [
                        {"type": "input_text", "text": label},
                        {"type": "input_image", "image_url": image_url},
                    ],
                }
            ],
            "stream": False,
            "metadata": {"include_confidence": "true"},
        }
        async with httpx.AsyncClient(timeout=timeout_sec) as client:
            resp = await client.post(
                f"{settings.meta_api_base_url.rstrip('/')}/responses",
                headers={"Authorization": f"Bearer {settings.meta_api_key}"},
                json=body,
            )
            resp.raise_for_status()
            return parse_sam_output_text(output_text_from_response(resp.json()), label=label)

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
