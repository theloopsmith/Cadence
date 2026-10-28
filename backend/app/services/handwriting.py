from typing import Any, Dict, List, Optional
import cv2
import numpy as np


def unreadable_handwriting() -> Dict[str, Any]:
    """A line with too few strokes to compare a start and an end."""
    return {
        "initial_stroke_height_px": None,
        "final_stroke_height_px": None,
        "opencv_cc_decay_pct": None,
        "handwriting_score": None,
        "micrographia_detected": False,
        "measured": False,
    }


def compute_decay_from_heights(heights_px: List[float]) -> Dict[str, Any]:
    """
    Computes progressive stroke height change (opencv_cc_decay_pct) from ordered
    character bounding box heights [h_1, ..., h_M].
    Negative when shrinking (e.g., -35.0 means 35% shrinkage).

    Fewer than four letters cannot show a start-versus-end change. Returning a
    perfect score there made a failed photo look like healthy writing.
    """
    if len(heights_px) < 4:
        return unreadable_handwriting()
    k = max(2, len(heights_px) // 3)
    h_first = float(np.mean(heights_px[:k]))
    h_last = float(np.mean(heights_px[-k:]))
    if h_first <= 1e-6:
        decay_pct = 0.0
    else:
        decay_pct = round(((h_last - h_first) / h_first) * 100.0, 1)

    shrinkage_pct = max(0.0, -decay_pct - 5.0)
    writing_score = round(max(0.0, min(100.0, 100.0 - 1.6 * shrinkage_pct)), 1)
    micrographia_detected = decay_pct <= -20.0

    return {
        "initial_stroke_height_px": round(h_first, 1),
        "final_stroke_height_px": round(h_last, 1),
        "opencv_cc_decay_pct": decay_pct,
        "handwriting_score": writing_score,
        "micrographia_detected": micrographia_detected,
        "measured": True,
    }


def analyze_handwriting_opencv(
    image_bytes: Optional[bytes],
    simulated_letter_heights_px: Optional[List[float]] = None,
    simulated_sam_decay_pct: Optional[float] = None,
) -> Dict[str, Any]:
    """
    Always-on local CPU OpenCV deskew + connected-components stroke height analyzer (<8ms).
    Always drives handwriting_score from opencv_cc_decay_pct so ON vs. OFF composite deltas
    never suffer method-switching artifacts.
    """
    boxes: List[Dict[str, int]] = []
    deskew_angle = 0.0

    if simulated_letter_heights_px is not None:
        metrics = compute_decay_from_heights(simulated_letter_heights_px)
        for idx, h in enumerate(simulated_letter_heights_px):
            boxes.append({"x": idx * 24, "y": 40, "w": 16, "h": int(round(h))})
        return {
            **metrics,
            "sam_3_1_decay_pct": simulated_sam_decay_pct,
            "deskew_angle_deg": deskew_angle,
            "letter_boxes": boxes,
        }

    if not image_bytes:
        return {
            **unreadable_handwriting(),
            "sam_3_1_decay_pct": simulated_sam_decay_pct,
            "deskew_angle_deg": 0.0,
            "letter_boxes": [],
        }

    arr = np.frombuffer(image_bytes, dtype=np.uint8)
    img = cv2.imdecode(arr, cv2.IMREAD_GRAYSCALE)
    if img is None:
        return {
            **unreadable_handwriting(),
            "sam_3_1_decay_pct": simulated_sam_decay_pct,
            "deskew_angle_deg": 0.0,
            "letter_boxes": [],
        }

    # Adaptive Gaussian thresholding + deskew via minAreaRect
    thresh = cv2.adaptiveThreshold(
        img, 255, cv2.ADAPTIVE_THRESH_GAUSSIAN_C, cv2.THRESH_BINARY_INV, 21, 10
    )
    coords = np.column_stack(np.where(thresh > 0))
    if len(coords) > 20:
        rect = cv2.minAreaRect(coords)
        angle = rect[-1]
        if angle < -45:
            angle = -(90 + angle)
        else:
            angle = -angle
        if abs(angle) <= 25.0:
            deskew_angle = round(float(angle), 2)
            h_img, w_img = thresh.shape[:2]
            rot_mat = cv2.getRotationMatrix2D((w_img // 2, h_img // 2), angle, 1.0)
            thresh = cv2.warpAffine(thresh, rot_mat, (w_img, h_img))

    num_labels, _, stats, _ = cv2.connectedComponentsWithStats(thresh, connectivity=8)
    raw_boxes = []
    for i in range(1, num_labels):
        x, y, w, h, area = (
            int(stats[i, cv2.CC_STAT_LEFT]),
            int(stats[i, cv2.CC_STAT_TOP]),
            int(stats[i, cv2.CC_STAT_WIDTH]),
            int(stats[i, cv2.CC_STAT_HEIGHT]),
            int(stats[i, cv2.CC_STAT_AREA]),
        )
        if area >= 15 and 4 <= h <= 200 and 2 <= w <= 150:
            raw_boxes.append({"x": x, "y": y, "w": w, "h": h})

    raw_boxes.sort(key=lambda b: b["x"])
    heights = [float(b["h"]) for b in raw_boxes]
    metrics = compute_decay_from_heights(heights)
    return {
        **metrics,
        "sam_3_1_decay_pct": simulated_sam_decay_pct,
        "deskew_angle_deg": deskew_angle,
        "letter_boxes": raw_boxes,
    }
