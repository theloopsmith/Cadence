import time
import math
import re
from typing import Any, Dict, List, Optional

from app.clients.baseten_llm import baseten_client
from app.clients.circuit_breaker import RequestDeadlineContext
from app.clients.meta_models import meta_client

LIVING_VOCAB = {"person", "human", "child", "cat", "dog", "animal"}
INANIMATE_VOCAB = {
    "chair",
    "armchair",
    "sofa",
    "coat",
    "coat rack",
    "jacket",
    "blanket",
    "pillow",
    "bag",
    "backpack",
    "lamp",
    "shadow",
    "curtain",
    "plant",
    "table",
    "desk",
    "door",
    "bed",
    "wall",
    "window",
    "cabinet",
    "shelf",
    "bookshelf",
    "television",
    "tv",
    "mirror",
    "box",
}

# Inanimate labels that stand upright in a room rather than resting on a seat.
# A coat rack in low light is one of the most common Parkinson's hallucination
# triggers, so it gets its own reassurance template instead of being described
# as something "on the seat".
UPRIGHT_FIXTURE_LABELS = {
    "coat rack", "lamp", "curtain", "plant", "shadow", "door", "wall", "window", "mirror", "cabinet", "shelf", "bookshelf"
}
CLOSED_REALITY_VOCAB = sorted(LIVING_VOCAB | INANIMATE_VOCAB)

# SAM 3.1 answers one noun phrase per request, so each photo gets a short
# list: the living things we always ask about, then whatever the wearer named.
ALWAYS_ASK_LIVING = ["person", "dog", "cat"]
DEFAULT_INANIMATE = ["chair", "coat"]
MAX_CONCEPTS_PER_PHOTO = 6


def named_inanimate_labels(user_query: str) -> List[str]:
    return [label for label in sorted(INANIMATE_VOCAB, key=len, reverse=True)
            if re.search(r"(?<!\w)" + re.escape(label) + r"s?(?!\w)", user_query.lower())]


def reality_check_concepts(user_query: str) -> List[str]:
    """The concepts to segment for one question, living ones first."""
    concepts = list(ALWAYS_ASK_LIVING)
    for label in named_inanimate_labels(user_query) + DEFAULT_INANIMATE:
        if label not in concepts and len(concepts) < MAX_CONCEPTS_PER_PHOTO:
            concepts.append(label)
    return concepts


def _confident_enough(mask: Dict[str, Any], floor: float = 0.65) -> bool:
    """SAM may omit confidence. Missing is not zero; only a stated low value is dropped."""
    confidence = mask.get("confidence")
    if confidence is None:
        return True
    try:
        value = float(confidence)
        return math.isfinite(value) and floor <= value <= 1
    except (ValueError, TypeError):
        return False


def mask_grounding_rule(mask: Dict[str, Any], requested: set[str]) -> Optional[str]:
    """Prototype heuristics, not calibrated certainty or a scene-safety test.

    An explicitly requested small object needs stated higher confidence and
    meaningful box dimensions. The ordinary rule stays conservative otherwise.
    """
    label = str(mask.get("label", "")).lower()
    if label not in CLOSED_REALITY_VOCAB or not _confident_enough(mask):
        return None
    try:
        area = float(mask.get("area_ratio", 0))
        if not math.isfinite(area) or not 0 < area <= 1:
            return None
        if area >= 0.015:
            return "frame_area"
        if label not in requested or not _confident_enough(mask, floor=0.8) or mask.get("confidence") is None:
            return None
        box = mask.get("box") or {}
        x1,y1,x2,y2,w,h = (int(box[key]) for key in ("x1","y1","x2","y2","w","h"))
        if 0 <= x1 <= x2 < w and 0 <= y1 <= y2 < h and min(x2-x1+1,y2-y1+1) >= 16:
            return "explicit_requested_object"
    except (ValueError, TypeError, KeyError):
        return None
    return None

LIVING_DENY_WORDS = {
    "person",
    "human",
    "man",
    "woman",
    "child",
    "someone",
    "somebody",
    "stranger",
    "visitor",
    "pet",
    "dog",
    "cat",
    "animal",
}


def render_grounded_template(
    template_id: str,
    label: Optional[str] = None,
    user_query: Optional[str] = None,
) -> str:
    if template_id == "CONFIRM_LIVING_SUBJECT" and label:
        return f"I can identify a {label} in this photo. I cannot verify the whole scene."
    if template_id == "REASSURE_SHADOW_OR_LIGHT" and label:
        return f"I can identify a {label} in this photo. I cannot confirm whether someone else is present."
    if template_id == "REASSURE_OBJECT_ON_SEAT" and label:
        return f"I can identify a {label} in this photo. I cannot confirm whether someone else is present."
    if template_id == "UNVERIFIED_LIGHTING_FALLBACK":
        return (
            "I couldn't get a clear view of the room in this light. "
            "Please turn on a light and try taking another photo."
        )
    return (
        "I cannot identify any clear objects in this frame. "
        "Try holding the camera steady or taking another photo at a wider angle."
    )


def contains_denied_living_word(sentence: str) -> bool:
    """Checks only the affirmative clause after any 'No one is...' reassurance prefix."""
    lowered = sentence.lower()
    # Strip standard reassurance openings that say 'no one'
    cleaned = lowered.replace("no one is sitting there", "").replace("no one is there", "").replace("no one is in that area", "")
    tokens = {
        tok.strip(".,!?;:—-\"'()") for tok in cleaned.split() if tok.strip()
    }
    return bool(tokens & LIVING_DENY_WORDS)


async def run_reality_check_pipeline(
    user_query: str,
    image_bytes: Optional[bytes],
    simulated_sam_masks: Optional[List[Dict[str, Any]]] = None,
    deadline: Optional[RequestDeadlineContext] = None,
) -> Dict[str, Any]:
    """
    Executes the Verifiable Hallucination Reality Check pipeline:
      1. SAM 3.1 masks filtered by confidence >= 0.65 & area_ratio >= 0.015 -> L_sam
      2. Deterministic Grounding Gate: locks inanimate slot strictly to L_inanimate,sam
      3. Baseten muse-spark-open-1026 slot selection + deny-list validation
      4. The phone speaks the reply with its own voice
    """
    ctx = deadline or RequestDeadlineContext()
    t0 = time.monotonic()

    sam_res = await meta_client.segment_sam_3_1(
        image_bytes=image_bytes,
        candidate_labels=reality_check_concepts(user_query),
        deadline=ctx,
        simulated_masks=simulated_sam_masks,
    )

    evidence = {
        "segmentation": {
            "source": "simulated" if sam_res.get("model") == "simulated" else "meta_model_api" if sam_res.get("model") else "unavailable",
            "model": sam_res.get("model"),
            "latency_ms": sam_res.get("latency_ms"),
            "failed_concepts": sam_res.get("failed_labels", []),
        },
        "selection": {"source":"deterministic_template", "model":None},
    }

    if not sam_res.get("sam_verified", False):
        spoken = render_grounded_template("UNVERIFIED_LIGHTING_FALLBACK", user_query=user_query)
        latency_ms = int((time.monotonic() - t0) * 1000)
        return {
            "model_evidence": evidence,
            "sam_verified": False,
            "verified_masks": [],
            "living_subject_present": False,
            "chosen_inanimate_label": None,
            "template_id": "UNVERIFIED_LIGHTING_FALLBACK",
            "spoken_response": spoken,
            "tts_source": "ios_on_device",
            "latency_ms": latency_ms,
        }

    # Keep ordinary scene evidence, plus strongly grounded small objects the
    # wearer actually named. A wide camera frame must not hide a requested lamp.
    raw_masks = sam_res.get("masks", [])
    requested = set(named_inanimate_labels(user_query))
    verified_masks = []
    for mask in raw_masks:
        rule = mask_grounding_rule(mask, requested)
        if rule:
            verified_masks.append({**mask, "grounding_rule":rule})
    # Stated confidence first, then size; a record without `c` sorts by size alone.
    verified_masks.sort(
        key=lambda m: (float(m["confidence"]) if m.get("confidence") is not None else 0.0, float(m.get("area_ratio", 0.0))),
        reverse=True,
    )

    living_masks = [
        m for m in verified_masks if str(m.get("label", "")).lower() in LIVING_VOCAB
    ]
    inanimate_masks = [
        m for m in verified_masks if str(m.get("label", "")).lower() in INANIMATE_VOCAB
    ]

    if living_masks:
        top_living = str(living_masks[0]["label"]).lower()
        template_id = "CONFIRM_LIVING_SUBJECT"
        chosen_label = None
        spoken = render_grounded_template(template_id, top_living, user_query=user_query)
    else:
        allowed_inanimate = [str(m["label"]).lower() for m in inanimate_masks]
        if not allowed_inanimate:
            template_id = "REASSURE_EMPTY_SPACE"
            chosen_label = None
            spoken = render_grounded_template(template_id, user_query=user_query)
        else:
            llm_choice = await baseten_client.choose_reality_check_slot(
                user_query=user_query,
                allowed_inanimate_labels=allowed_inanimate,
                deadline=ctx,
            )
            if (
                llm_choice
                and llm_choice.get("chosen_label") in allowed_inanimate
            ):
                evidence["selection"] = {
                    "source":"meta_open_weights" if llm_choice.get("model") else "unreported",
                    "provider":llm_choice.get("provider"), "model":llm_choice.get("model"),
                    "latency_ms":llm_choice.get("latency_ms"),
                }
                chosen_label = llm_choice["chosen_label"]
                template_id = llm_choice["template_id"]
            else:
                # Deterministic fallback: pick top-confidence inanimate label in L_sam
                chosen_label = allowed_inanimate[0]
                template_id = (
                    "REASSURE_SHADOW_OR_LIGHT"
                    if chosen_label in UPRIGHT_FIXTURE_LABELS
                    else "REASSURE_OBJECT_ON_SEAT"
                )
            spoken = render_grounded_template(template_id, chosen_label, user_query=user_query)
            if contains_denied_living_word(chosen_label):
                template_id = "REASSURE_EMPTY_SPACE"
                chosen_label = None
                spoken = render_grounded_template(template_id, user_query=user_query)

    latency_ms = int((time.monotonic() - t0) * 1000)

    return {
        "model_evidence": evidence,
        "sam_verified": True,
        "verified_masks": verified_masks,
        "living_subject_present": bool(living_masks),
        "chosen_inanimate_label": chosen_label,
        "template_id": template_id,
        "spoken_response": spoken,
        "tts_source": "ios_on_device",
        "latency_ms": latency_ms,
    }
