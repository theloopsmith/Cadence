import time
import asyncio
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
    "box", "cup", "mug", "bottle", "plate", "bowl", "book", "notebook", "phone",
    "laptop", "computer", "monitor", "keyboard", "sink", "counter", "pen",
}

# Legacy template IDs distinguish fixtures from objects; neither is reassurance
# about whether a person is present or whether the scene is safe.
UPRIGHT_FIXTURE_LABELS = {
    "coat rack", "lamp", "curtain", "plant", "shadow", "door", "wall", "window", "mirror", "cabinet", "shelf", "bookshelf"
}
CLOSED_REALITY_VOCAB = sorted(LIVING_VOCAB | INANIMATE_VOCAB)

# SAM 3.1 answers one noun phrase per request, so each photo gets a short
# list: the living things we always ask about, then whatever the wearer named.
ALWAYS_ASK_LIVING = ["person", "dog", "cat"]
DEFAULT_INANIMATE = ["chair", "table", "sofa"]
MAX_CONCEPTS_PER_PHOTO = 6


def named_inanimate_labels(user_query: str) -> List[str]:
    return [label for label in sorted(INANIMATE_VOCAB, key=len, reverse=True)
            if re.search(r"(?<!\w)" + re.escape(label) + r"s?(?!\w)", user_query.lower())]


def named_living_labels(user_query: str) -> set[str]:
    words = set(re.findall(r"\w+", user_query.lower()))
    labels = {label for label in ALWAYS_ASK_LIVING if words & {label, label + "s"}}
    if words & {"people", "human", "humans", "someone", "anyone", "somebody", "anybody", "child", "man", "woman"}:
        labels.add("person")
    return labels


def reality_check_concepts(user_query: str, proposed: Optional[List[str]] = None) -> List[str]:
    """The concepts to segment for one question, living ones first."""
    concepts = list(ALWAYS_ASK_LIVING)
    for label in named_inanimate_labels(user_query) + [v for v in (proposed or []) if v in INANIMATE_VOCAB] + DEFAULT_INANIMATE:
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
        return f"The photo check suggests a {label}. This may be mistaken; I cannot verify the whole scene."
    if template_id == "REASSURE_SHADOW_OR_LIGHT" and label:
        return f"The photo check suggests a {label} in this photo. This may be mistaken; I cannot confirm whether someone else is present."
    if template_id == "REASSURE_OBJECT_ON_SEAT" and label:
        return f"The photo check suggests a {label} in this photo. This may be mistaken; I cannot confirm whether someone else is present."
    if template_id == "UNVERIFIED_LIGHTING_FALLBACK":
        return (
            "I couldn't complete the photo check. The image service may be unavailable. "
            "Please retry this photo or check the server connection."
        )
    return (
        "I couldn't verify the objects I searched for in this photo. "
        "Ask about a specific object, or choose another photo. I cannot verify the whole scene."
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
    Executes a bounded, fallible photo-label pipeline:
      1. SAM 3.1 masks filtered by confidence >= 0.65 & area_ratio >= 0.015 -> L_sam
      2. Deterministic Grounding Gate: locks inanimate slot strictly to L_inanimate,sam
      3. Baseten muse-spark-open-1026 slot selection + deny-list validation
      4. The phone speaks the reply with its own voice
    """
    ctx = deadline or RequestDeadlineContext()
    t0 = time.monotonic()

    proposal = None
    # Search for living subjects while vision proposes object terms. Waiting for
    # vision first would spend most of the shared deadline before SAM could run.
    if image_bytes and simulated_sam_masks is None and not named_inanimate_labels(user_query):
        from app.config import settings
        if settings.baseten_api_key:
            discovery = asyncio.create_task(baseten_client.propose_scene_labels(image_bytes, sorted(INANIMATE_VOCAB), ctx))
            try:
                initial = await meta_client.segment_sam_3_1(image_bytes=image_bytes,
                    candidate_labels=ALWAYS_ASK_LIVING,
                    deadline=RequestDeadlineContext(total_budget_sec=min(3.2, max(0, ctx.remaining_sec()-.5))))
                proposal = await discovery
            finally:
                if not discovery.done():
                    discovery.cancel()
                    await asyncio.gather(discovery, return_exceptions=True)
            concepts = reality_check_concepts(user_query, proposal.get("labels") if proposal else None)
            objects = [label for label in concepts if label not in ALWAYS_ASK_LIVING]
            found = await meta_client.segment_sam_3_1(image_bytes=image_bytes, candidate_labels=objects,
                deadline=RequestDeadlineContext(total_budget_sec=max(0, ctx.remaining_sec()-.5)))
            sam_res = {"sam_verified": bool(initial.get("sam_verified") and found.get("sam_verified")),
                       "masks": initial.get("masks",[]) + found.get("masks",[]),
                       "failed_labels": initial.get("failed_labels",[]) + found.get("failed_labels",[]),
                       "model": found.get("model") or initial.get("model"),
                       "latency_ms": initial.get("latency_ms",0) + found.get("latency_ms",0)}
        else:
            concepts = reality_check_concepts(user_query)
            sam_res = await meta_client.segment_sam_3_1(image_bytes=image_bytes, candidate_labels=concepts, deadline=ctx)
    else:
        concepts = reality_check_concepts(user_query)
        sam_res = await meta_client.segment_sam_3_1(image_bytes=image_bytes, candidate_labels=concepts,
            simulated_masks=simulated_sam_masks, deadline=ctx)

    evidence = {
        "proposal": {k:v for k,v in proposal.items() if k != "labels"} if proposal else {"source":"deterministic_search_terms", "model":None},
        "segmentation": {
            "source": "simulated" if sam_res.get("model") == "simulated" else "meta_model_api" if sam_res.get("model") else "unavailable",
            "model": sam_res.get("model"),
            "latency_ms": sam_res.get("latency_ms"),
            "failed_concepts": sam_res.get("failed_labels", []),
        },
        "selection": {"source":"deterministic_template", "model":None},
    }

    if not sam_res.get("sam_verified", False) and not sam_res.get("masks"):
        spoken = render_grounded_template("UNVERIFIED_LIGHTING_FALLBACK", user_query=user_query)
        latency_ms = int((time.monotonic() - t0) * 1000)
        return {
            "analysis_status": "unavailable",
            "searched_concepts": concepts,
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

    # A living detection must not suppress the requested object or all other
    # scene evidence. SAM answers a prompted noun; a returned box is not proof
    # that this noun is correct, even when no confidence value is supplied.
    living_requested = named_living_labels(user_query) if not requested else set()
    targets = requested or living_requested
    relevant_living = [m for m in living_masks if not targets or m["label"] in targets]
    relevant_inanimate = [m for m in inanimate_masks if not targets or m["label"] in targets]
    if relevant_living and not relevant_inanimate:
        top_living = str(relevant_living[0]["label"]).lower()
        template_id = "CONFIRM_LIVING_SUBJECT"
        chosen_label = None
        spoken = render_grounded_template(template_id, top_living, user_query=user_query)
    else:
        allowed_inanimate = list(dict.fromkeys(str(m["label"]).lower() for m in relevant_inanimate))
        if not allowed_inanimate:
            template_id = "REASSURE_EMPTY_SPACE"
            chosen_label = None
            spoken = render_grounded_template(template_id, user_query=user_query)
        else:
            llm_choice = await baseten_client.choose_reality_check_slot(
                user_query=user_query,
                allowed_inanimate_labels=allowed_inanimate,
                deadline=RequestDeadlineContext(total_budget_sec=max(0, ctx.remaining_sec()-.3)),
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

    if verified_masks and not targets:
        # Include both kinds of evidence instead of repeating the first living
        # label. Reserve room for a living candidate when objects are present.
        objects = list(dict.fromkeys(([chosen_label] if chosen_label else []) + [str(m['label']) for m in inanimate_masks]))
        living = list(dict.fromkeys(str(m['label']) for m in living_masks))
        labels = objects[:2] + living[:1] if objects and living else (objects or living)[:3]
        words = labels[0] if len(labels) == 1 else ', '.join(labels[:-1]) + ' and ' + labels[-1]
        spoken = "The photo check suggests " + words + ". These detections may be mistaken; I cannot verify the whole scene."
    elif targets and not (relevant_inanimate or relevant_living):
        spoken = "I couldn't get a supported match for " + ', '.join(sorted(targets)) + ". That does not mean it is absent. Try another photo of the area you want to check."
    if verified_masks and not sam_res.get("sam_verified"):
        spoken += " Some object checks did not finish."
    if not verified_masks and not sam_res.get("sam_verified"):
        template_id = "UNVERIFIED_LIGHTING_FALLBACK"
        spoken = render_grounded_template(template_id)
    latency_ms = int((time.monotonic() - t0) * 1000)

    supported_for_query = relevant_inanimate + relevant_living
    return {
        "analysis_status": ("partial" if not sam_res.get("sam_verified") else "identified") if supported_for_query else ("no_supported_match" if sam_res.get("sam_verified") else "unavailable"),
        "searched_concepts": concepts,
        "model_evidence": evidence,
        "sam_verified": bool(sam_res.get("sam_verified")),
        "verified_masks": verified_masks,
        "living_subject_present": bool(living_masks),
        "chosen_inanimate_label": chosen_label,
        "template_id": template_id,
        "spoken_response": spoken,
        "tts_source": "ios_on_device",
        "latency_ms": latency_ms,
    }
