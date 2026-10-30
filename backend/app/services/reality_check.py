import time
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
}

# Inanimate labels that stand upright in a room rather than resting on a seat.
# A coat rack in low light is one of the most common Parkinson's hallucination
# triggers, so it gets its own reassurance template instead of being described
# as something "on the seat".
UPRIGHT_FIXTURE_LABELS = {"coat rack", "lamp", "curtain", "plant", "shadow"}
CLOSED_REALITY_VOCAB = sorted(LIVING_VOCAB | INANIMATE_VOCAB)

# SAM 3.1 answers one noun phrase per request, so each photo gets a short
# list: the living things we always ask about, then whatever the wearer named.
ALWAYS_ASK_LIVING = ["person", "dog", "cat"]
DEFAULT_INANIMATE = ["chair", "coat"]
MAX_CONCEPTS_PER_PHOTO = 6


def reality_check_concepts(user_query: str) -> List[str]:
    """The concepts to segment for one question, living ones first."""
    lowered = f" {user_query.lower()} "
    named = [
        label
        for label in sorted(INANIMATE_VOCAB, key=len, reverse=True)
        if f" {label} " in lowered or f" {label}s " in lowered or f" {label}? " in lowered
    ]
    concepts = list(ALWAYS_ASK_LIVING)
    for label in named + DEFAULT_INANIMATE:
        if label not in concepts and len(concepts) < MAX_CONCEPTS_PER_PHOTO:
            concepts.append(label)
    return concepts


def _confident_enough(mask: Dict[str, Any], floor: float = 0.65) -> bool:
    """SAM may omit confidence. Missing is not zero; only a stated low value is dropped."""
    confidence = mask.get("confidence")
    if confidence is None:
        return True
    return float(confidence) >= floor

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


def render_grounded_template(template_id: str, label: Optional[str] = None) -> str:
    if template_id == "CONFIRM_LIVING_SUBJECT" and label:
        return f"I can identify a {label} in this photo. I cannot verify the whole scene."
    if template_id == "REASSURE_SHADOW_OR_LIGHT" and label:
        return f"I can identify a {label} in this photo. I cannot confirm whether someone else is present."
    if template_id == "REASSURE_OBJECT_ON_SEAT" and label:
        return f"I can identify a {label} in this photo. I cannot confirm whether someone else is present."
    if template_id == "UNVERIFIED_LIGHTING_FALLBACK":
        return (
            "I couldn't get a clear view of the room right now. "
            "Please turn on a light or ask someone nearby."
        )
    return "I cannot identify any clear objects in this frame. Try another view or ask someone nearby."


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

    if not sam_res.get("sam_verified", False):
        spoken = render_grounded_template("UNVERIFIED_LIGHTING_FALLBACK")
        latency_ms = int((time.monotonic() - t0) * 1000)
        return {
            "sam_verified": False,
            "verified_masks": [],
            "living_subject_present": False,
            "chosen_inanimate_label": None,
            "template_id": "UNVERIFIED_LIGHTING_FALLBACK",
            "spoken_response": spoken,
            "tts_source": "ios_on_device",
            "latency_ms": latency_ms,
        }

    # Keep masks that are at least 1.5% of the frame and not stated to be low confidence.
    raw_masks = sam_res.get("masks", [])
    verified_masks = [
        m
        for m in raw_masks
        if _confident_enough(m)
        and float(m.get("area_ratio", 0.0)) >= 0.015
        and str(m.get("label", "")).lower() in CLOSED_REALITY_VOCAB
    ]
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
        spoken = render_grounded_template(template_id, top_living)
    else:
        allowed_inanimate = [str(m["label"]).lower() for m in inanimate_masks]
        if not allowed_inanimate:
            template_id = "REASSURE_EMPTY_SPACE"
            chosen_label = None
            spoken = render_grounded_template(template_id)
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
            spoken = render_grounded_template(template_id, chosen_label)
            if contains_denied_living_word(chosen_label):
                template_id = "REASSURE_EMPTY_SPACE"
                chosen_label = None
                spoken = render_grounded_template(template_id)

    latency_ms = int((time.monotonic() - t0) * 1000)

    return {
        "sam_verified": True,
        "verified_masks": verified_masks,
        "living_subject_present": bool(living_masks),
        "chosen_inanimate_label": chosen_label,
        "template_id": template_id,
        "spoken_response": spoken,
        "tts_source": "ios_on_device",
        "latency_ms": latency_ms,
    }
