from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Any, Dict, List, Optional


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
    Computes pure motor/biomechanical symptom burden S(t_k) in [0, 100]:
      S(t_k) = min(100,
          28.0 * I_fall
        + 12.0 * n_fog
        + 18.0 * max(0, mean_FI - 1.5)
        + 15.0 * max(0, (-opencv_decay_pct - 15.0) / 25.0)
        + 10.0 * max(0, (-30.0 - mean_voice_dbfs) / 10.0)
        + I_has_exam * 20.0 * max(0, (70.0 - S_motor) / 70.0)
      )
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


def _parse_utc(ts_str: str) -> Optional[datetime]:
    try:
        dt = datetime.fromisoformat(str(ts_str).replace("Z", "+00:00"))
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt.astimezone(timezone.utc)
    except Exception:
        return None


def build_24h_diary_timeline(
    fog_rows: List[Dict[str, Any]],
    fall_rows: List[Dict[str, Any]],
    med_rows: List[Dict[str, Any]],
    writing_rows: List[Dict[str, Any]],
    voice_rows: List[Dict[str, Any]],
    exam_rows: List[Dict[str, Any]],
    reference_end_utc: Optional[datetime] = None,
) -> Dict[str, Any]:
    """
    Aggregates all patient telemetry over the trailing 24 hours into 30-minute
    clinical diary buckets (up to 48 buckets) and classifies each bucket using
    classify_diary_bucket(). Also computes ON vs. OFF Home Motor Exam deltas.
    """
    # Determine anchor time from latest event or current UTC time
    all_timestamps: List[datetime] = []
    for rows in (fog_rows, fall_rows, med_rows, writing_rows, voice_rows, exam_rows):
        for r in rows:
            dt = _parse_utc(str(r.get("timestamp_utc", "")))
            if dt:
                all_timestamps.append(dt)

    end_time = reference_end_utc or (max(all_timestamps) if all_timestamps else datetime.now(timezone.utc))
    # Align end_time up to the next 30-minute boundary
    minute_floor = (end_time.minute // 30) * 30
    bucket_end_anchor = end_time.replace(minute=minute_floor, second=0, microsecond=0) + timedelta(minutes=30)

    # Extract doses & protein-conflict meals
    doses: List[datetime] = []
    conflict_meals: List[datetime] = []
    for m in med_rows:
        dt = _parse_utc(str(m.get("timestamp_utc", "")))
        if not dt:
            continue
        if m.get("event_type") == "dose_taken":
            doses.append(dt)
        elif m.get("event_type") == "meal_logged" and int(m.get("conflict_detected", 0)) == 1:
            conflict_meals.append(dt)
    doses.sort()

    # Build 16 buckets (8-hour active clinical window) or 48 buckets (24-hour window)
    # Using buckets that cover the span of recorded events (min 8 buckets for compact view)
    if all_timestamps:
        earliest = min(all_timestamps)
        earliest_floor = earliest.replace(
            minute=(earliest.minute // 30) * 30, second=0, microsecond=0
        )
        span_buckets = max(8, min(48, int((bucket_end_anchor - earliest_floor).total_seconds() // 1800)))
    else:
        span_buckets = 8

    start_anchor = bucket_end_anchor - timedelta(minutes=30 * span_buckets)
    buckets: List[Dict[str, Any]] = []
    state_counts = {"ON": 0, "WEARING_OFF": 0, "OFF": 0, "NO_DOSE": 0}

    for k in range(span_buckets):
        b_start = start_anchor + timedelta(minutes=30 * k)
        b_end = b_start + timedelta(minutes=30)

        # Filter events in [b_start, b_end)
        b_fogs = [
            r for r in fog_rows
            if (dt := _parse_utc(str(r.get("timestamp_utc", "")))) and b_start <= dt < b_end
        ]
        b_falls = [
            r for r in fall_rows
            if (dt := _parse_utc(str(r.get("timestamp_utc", ""))))
            and b_start <= dt < b_end
            and r.get("status") not in {"canceled_false_alarm", "suppressed_unworn_drop"}
        ]
        b_writings = [
            r for r in writing_rows
            if (dt := _parse_utc(str(r.get("timestamp_utc", "")))) and b_start <= dt < b_end
        ]
        b_voices = [
            r for r in voice_rows
            if (dt := _parse_utc(str(r.get("timestamp_utc", "")))) and b_start <= dt < b_end
        ]
        b_exams = [
            r for r in exam_rows
            if (dt := _parse_utc(str(r.get("timestamp_utc", "")))) and b_start <= dt < b_end
        ]

        # Most recent dose at or before b_end (within last 12 hours)
        prior_doses = [d for d in doses if d <= b_end and (b_end - d).total_seconds() <= 12 * 3600]
        if prior_doses:
            last_dose = prior_doses[-1]
            has_dose = True
            mins_since_dose = int((b_end - last_dose).total_seconds() // 60)
            protein_conflict = any(
                abs((cm - last_dose).total_seconds()) <= 60 * 60 for cm in conflict_meals
            )
        else:
            has_dose = False
            mins_since_dose = None
            protein_conflict = False

        fog_count = len(b_fogs) + sum(int(ex.get("walk_fog_count", 0)) for ex in b_exams)
        fi_values = [float(r["peak_freeze_index"]) for r in b_fogs] + [
            float(ex["walk_mean_fi"]) for ex in b_exams
        ]
        mean_fi = max(fi_values) if fi_values else 0.8

        decay_values = [float(w["opencv_cc_decay_pct"]) for w in b_writings] + [
            float(ex["handwriting_opencv_decay_pct"]) for ex in b_exams
        ]
        worst_decay = min(decay_values) if decay_values else 0.0

        voice_values = [float(v["window_mean_dbfs"]) for v in b_voices] + [
            float(ex["voice_mean_dbfs"]) for ex in b_exams
        ]
        mean_voice = min(voice_values) if voice_values else -22.0

        has_exam = len(b_exams) > 0
        exam_score = float(b_exams[-1]["composite_motor_score"]) if has_exam else 100.0

        metrics = DiaryBucketMetrics(
            fall_occurred=len(b_falls) > 0,
            fog_count=fog_count,
            mean_fi=mean_fi,
            opencv_decay_pct=worst_decay,
            mean_voice_dbfs=mean_voice,
            has_exam=has_exam,
            exam_composite_score=exam_score,
            has_dose=has_dose,
            minutes_since_last_dose=mins_since_dose,
            protein_conflict_active=protein_conflict,
        )
        classified = classify_diary_bucket(metrics)
        state = classified["clinical_state"]
        state_counts[state] += 1

        buckets.append(
            {
                "bucket_start_utc": b_start.isoformat(),
                "bucket_end_utc": b_end.isoformat(),
                "label_hhmm": b_start.strftime("%H:%M"),
                "clinical_state": state,
                "symptom_burden_score": classified["symptom_burden_score"],
                "fog_count": fog_count,
                "fall_occurred": len(b_falls) > 0,
                "has_exam": has_exam,
                "exam_composite_score": exam_score if has_exam else None,
                "minutes_since_last_dose": mins_since_dose,
                "protein_conflict_active": protein_conflict,
            }
        )

    total_b = max(1, len(buckets))
    # Compute ON vs. OFF Motor Exam comparison delta if exams exist in both states
    on_exams = [ex for ex in exam_rows if ex.get("medication_state_label") == "ON"]
    off_exams = [ex for ex in exam_rows if ex.get("medication_state_label") in {"OFF", "WEARING_OFF"}]
    exam_delta: Optional[Dict[str, float]] = None
    if on_exams and off_exams:
        on_latest = on_exams[0]
        off_latest = off_exams[0]
        exam_delta = {
            "on_composite": round(float(on_latest["composite_motor_score"]), 1),
            "off_composite": round(float(off_latest["composite_motor_score"]), 1),
            "composite_improvement_pts": round(
                float(on_latest["composite_motor_score"]) - float(off_latest["composite_motor_score"]), 1
            ),
            "voice_delta_pts": round(
                float(on_latest["voice_score"]) - float(off_latest["voice_score"]), 1
            ),
            "writing_delta_pts": round(
                float(on_latest["handwriting_score"]) - float(off_latest["handwriting_score"]), 1
            ),
            "gait_delta_pts": round(
                float(on_latest["gait_score"]) - float(off_latest["gait_score"]), 1
            ),
        }

    return {
        "buckets": buckets,
        "state_counts": state_counts,
        "on_pct": round(100.0 * state_counts["ON"] / total_b, 1),
        "wearing_off_pct": round(100.0 * state_counts["WEARING_OFF"] / total_b, 1),
        "off_pct": round(100.0 * state_counts["OFF"] / total_b, 1),
        "no_dose_pct": round(100.0 * state_counts["NO_DOSE"] / total_b, 1),
        "exam_on_vs_off_delta": exam_delta,
    }
