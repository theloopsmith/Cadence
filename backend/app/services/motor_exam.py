from dataclasses import dataclass
from typing import Dict, Optional


@dataclass
class MotorExamInput:
    voice_mean_dbfs: float
    voice_stability_db: float             # Computed strictly over 5s sustained vowel ("Ahhh")
    handwriting_opencv_decay_pct: float   # Negative when shrinking (e.g., -35.0 for 35% shrinkage)
    handwriting_sam_decay_pct: Optional[float]
    walk_cadence_spm: float
    walk_mean_fi: float
    walk_fog_count: int


def score_home_motor_exam(inp: MotorExamInput) -> Dict[str, float]:
    """
    Deterministic 0-100 scoring for the 3-step Guided Home Motor Exam:
      1. Voice Score (0-100): mean dBFS + 5s vowel-only phonation stability sigma_dB
      2. Method-Invariant Handwriting Score (0-100): always derived from opencv_cc_decay_pct
      3. Gait Score (0-100): cadence, mean Freeze Index FI, and freeze count
      4. Composite Score (0-100): 0.30*Voice + 0.30*Writing + 0.40*Gait
    """
    # 1. Voice Score (0-100) using 5s vowel phonation stability
    loudness_deficit = max(0.0, -24.0 - inp.voice_mean_dbfs)
    phonation_instability = max(0.0, inp.voice_stability_db - 2.0)
    voice_score = max(
        0.0, min(100.0, 100.0 - 2.5 * loudness_deficit - 8.0 * phonation_instability)
    )

    # 2. Method-Invariant Handwriting Score (0-100)
    shrinkage_pct = max(0.0, -inp.handwriting_opencv_decay_pct - 5.0)
    writing_score = max(0.0, min(100.0, 100.0 - 1.6 * shrinkage_pct))

    # 3. Gait Score (0-100)
    cadence_deficit = max(0.0, 105.0 - inp.walk_cadence_spm)
    fi_excess = max(0.0, inp.walk_mean_fi - 1.2)
    gait_score = max(
        0.0,
        min(
            100.0,
            100.0
            - 1.2 * cadence_deficit
            - 18.0 * fi_excess
            - 25.0 * inp.walk_fog_count,
        ),
    )

    composite = round(
        0.30 * voice_score + 0.30 * writing_score + 0.40 * gait_score, 1
    )
    return {
        "voice_score": round(voice_score, 1),
        "handwriting_score": round(writing_score, 1),
        "gait_score": round(gait_score, 1),
        "composite_motor_score": composite,
    }
