from datetime import datetime
from typing import Any, Dict, List, Optional

PROTEIN_LOOKUP_TABLE: Dict[str, Dict[str, float]] = {
    "steak":   {"grams": 28.0, "r_ref": 0.35},
    "beef":    {"grams": 28.0, "r_ref": 0.35},
    "chicken": {"grams": 26.0, "r_ref": 0.32},
    "poultry": {"grams": 26.0, "r_ref": 0.32},
    "salmon":  {"grams": 23.0, "r_ref": 0.30},
    "fish":    {"grams": 22.0, "r_ref": 0.30},
    "pork":    {"grams": 24.0, "r_ref": 0.32},
    "eggs":    {"grams": 12.0, "r_ref": 0.25},
    "cheese":  {"grams": 10.0, "r_ref": 0.20},
    "tofu":    {"grams": 10.0, "r_ref": 0.25},
    "beans":   {"grams": 9.0,  "r_ref": 0.25},
    "lentils": {"grams": 9.0,  "r_ref": 0.25},
    "yogurt":  {"grams": 8.0,  "r_ref": 0.25},
}

PLATE_LABELS = {"plate", "bowl", "platter", "dish"}
FOOD_CANDIDATE_VOCAB = list(PROTEIN_LOOKUP_TABLE.keys()) + list(PLATE_LABELS)


def mask_area(mask: Dict[str, Any]) -> float:
    """
    Returns a mask's area on whatever scale the provider reported it.

    SAM 3.1 returns absolute pixel area (``area_px``); replay fixtures and the
    dashboard's simulated masks report fractional frame coverage
    (``area_ratio``). Only the food-to-plate *quotient* is used downstream, so
    either unit yields the same normalized ratio as long as every mask in one
    frame uses the same one. Accepting both keys keeps a frame that reports
    coverage from silently degrading to the no-plate ``scale = 1.0`` fallback.
    """
    if "area_px" in mask:
        return float(mask.get("area_px") or 0.0)
    if "area_ratio" in mask:
        return float(mask.get("area_ratio") or 0.0)
    return 0.0


def estimate_meal_protein(masks: List[Dict[str, Any]]) -> Dict[str, Any]:
    """
    Computes plate-normalized protein grams from SAM 3.1 masks.
    If no plate/bowl mask is detected, falls back to scale = 1.0 (1.0x reference serving).
    """
    plate_area = max(
        (
            mask_area(m)
            for m in masks
            if str(m.get("label", "")).lower() in PLATE_LABELS
            and float(m.get("confidence", 0.0)) >= 0.60
        ),
        default=0.0,
    )
    total_grams = 0.0
    detected_items: List[Dict[str, Any]] = []
    ratios: List[float] = []

    for m in masks:
        label = str(m.get("label", "")).lower()
        conf = float(m.get("confidence", 0.0))
        area = mask_area(m)
        if label not in PROTEIN_LOOKUP_TABLE or conf < 0.60:
            continue
        spec = PROTEIN_LOOKUP_TABLE[label]
        if plate_area > 0.0:
            item_plate_ratio = area / plate_area
            ratios.append(item_plate_ratio)
            scale = max(0.5, min(2.0, item_plate_ratio / spec["r_ref"]))
        else:
            item_plate_ratio = None
            scale = 1.0
        grams = round(spec["grams"] * scale, 1)
        total_grams += grams
        detected_items.append(
            {
                "label": label,
                "scale": round(scale, 2),
                "estimated_grams": grams,
                "plate_area_ratio": round(item_plate_ratio, 3)
                if item_plate_ratio is not None
                else None,
            }
        )

    return {
        "plate_detected": plate_area > 0.0,
        "plate_area_ratio": round(sum(ratios), 3) if ratios else None,
        "estimated_protein_grams": round(total_grams, 1),
        "items": detected_items,
    }


def check_dose_protein_conflict(
    meal_timestamp_iso: str,
    estimated_protein_grams: float,
    dose_timestamp_iso: Optional[str],
) -> bool:
    """
    Flags conflict_detected = True if Protein > 15g and meal falls within
    [Dose - 45 min, Dose + 60 min].
    """
    if estimated_protein_grams <= 15.0 or not dose_timestamp_iso:
        return False
    try:
        t_meal = datetime.fromisoformat(meal_timestamp_iso.replace("Z", "+00:00"))
        t_dose = datetime.fromisoformat(dose_timestamp_iso.replace("Z", "+00:00"))
        delta_min = (t_meal - t_dose).total_seconds() / 60.0
        return -45.0 <= delta_min <= 60.0
    except Exception:
        return False
