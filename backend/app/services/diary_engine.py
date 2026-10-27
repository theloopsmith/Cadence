from dataclasses import dataclass
from typing import Any, Dict, Optional


@dataclass
class DiaryBucketMetrics:
    fall_occurred: bool = False
    fog_count: int = 0
    mean_fi: float = 0.8
    opencv_decay_pct: float = 0.0         # Negative when shrinking
    mean_voice_dbfs: float = -22.0
    has_exam: bool = False
    exam_composite_score: float = 100.0
    has_dose: bool = False
    minutes_since_last_dose: Optional[int] = None
    protein_conflict_active: bool = False


def compute_bucket_symptom_burden(m: DiaryBucketMetrics) -> float:
    """
    Computes pure motor/biomechanical symptom burden S(t_k) in [0, 100].
    Protein conflicts and hallucination checks are logged as discrete timeline
    markers rather than inflated into motor burden.
    """
    s_fall = 28.0 if m.fall_occurred else 0.0
    s_fog = 12.0 * m.fog_count
    s_fi = 18.0 * max(0.0, m.mean_fi - 1.5)
    s_write = 15.0 * max(0.0, (-m.opencv_decay_pct - 15.0) / 25.0)
    s_voice = 10.0 * max(0.0, (-30.0 - m.mean_voice_dbfs) / 10.0)
    s_exam = (
        20.0 * max(0.0, (70.0 - m.exam_composite_score) / 70.0)
        if m.has_exam
        else 0.0
    )
    return round(min(100.0, s_fall + s_fog + s_fi + s_write + s_voice + s_exam), 1)


def classify_diary_bucket(m: DiaryBucketMetrics) -> Dict[str, Any]:
    """
    Strictly ordered, exhaustive 4-state clinical classifier:
    1. OFF -> 2. NO_DOSE -> 3. WEARING_OFF -> 4. ON
    """
    burden = compute_bucket_symptom_burden(m)

    # 1. OFF (Red): High motor burden, >=2 freezes, fall, or low completed exam score
    if (
        burden >= 45.0
        or m.fog_count >= 2
        or m.fall_occurred
        or (m.has_exam and m.exam_composite_score < 55.0)
    ):
        state = "OFF"
    # 2. NO_DOSE (Neutral Grey): No Levodopa dose logged at or before t_k
    elif not m.has_dose or m.minutes_since_last_dose is None:
        state = "NO_DOSE"
    # 3. WEARING_OFF (Amber): Moderate burden [20, 45), OR mild burden (>= 10.0)
    #    when outside [30m, 180m] therapeutic window or with active protein conflict
    elif 20.0 <= burden < 45.0 or (
        (
            m.minutes_since_last_dose > 180
            or m.minutes_since_last_dose < 30
            or m.protein_conflict_active
        )
        and burden >= 10.0
    ):
        state = "WEARING_OFF"
    # 4. ON (Green): Remaining post-dose buckets with low symptom burden
    else:
        state = "ON"

    return {"symptom_burden_score": burden, "clinical_state": state}
