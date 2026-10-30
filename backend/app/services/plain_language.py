"""Words people read: counts of events and raw measurements, never a clinical
state, a score, or advice. Cadence is a companion, not a medical device."""

import re
from typing import Any, Dict, List, Optional

# Words that would turn a description into a clinical claim.
_NOT_PLAIN = re.compile(
    r"\b(ON|OFF|WEARING[_ -]?OFF|score|composite|/100|clinical|symptom|severity|"
    r"micrographia|hallucinat\w*|diagnos\w*|dose (change|adjust\w*)|increase|decrease)\b",
    re.IGNORECASE,
)


def is_plain(text: str) -> bool:
    """True when `text` describes events without clinical terms or advice."""
    return bool(text.strip()) and _NOT_PLAIN.search(text) is None


def _plural(count: int, one: str, many: str) -> str:
    return f"{count} {one if count == 1 else many}"


def describe_letter_change(decay_pct: Optional[float]) -> str:
    if decay_pct is None:
        return "handwriting was not measured"
    if abs(decay_pct) < 5.0:
        return "letters stayed about the same size across the line"
    size = abs(round(decay_pct))
    direction = "smaller" if decay_pct < 0 else "larger"
    return f"letters got {size}% {direction} across the line"


def describe_task_metrics(
    voice_mean_dbfs: Optional[float],
    handwriting_decay_pct: Optional[float],
    walk_cadence_spm: Optional[float],
    walk_fog_count: Optional[int],
) -> str:
    parts: List[str] = [describe_letter_change(handwriting_decay_pct)]
    if voice_mean_dbfs is not None:
        parts.append(f"the “Ahhh” averaged {round(voice_mean_dbfs)} dB")
    else:
        parts.append("voice was not measured")
    if walk_cadence_spm is not None:
        parts.append(f"walking was {round(walk_cadence_spm)} steps a minute")
    else:
        parts.append("walking was not measured")
    if walk_fog_count:
        parts.append(f"{_plural(int(walk_fog_count), 'freeze', 'freezes')} during the walk")
    return ", ".join(parts)


def summarize_day(stats: Dict[str, Any]) -> str:
    """Plain counts for the last 24 hours, for the wearer and their care team."""
    doses = int(stats.get("dose_count", 0) or 0)
    freezes = int(stats.get("fog_count", 0) or 0)
    falls = int(stats.get("fall_count", 0) or 0)
    answered = int(stats.get("fall_candidate_resolved_count", 0) or 0)

    sentences: List[str] = []
    events: List[str] = []
    if doses:
        events.append(f"{_plural(doses, 'dose', 'doses')} logged")
    if freezes:
        events.append(f"{_plural(freezes, 'walking pause', 'walking pauses')} logged")
    if falls:
        events.append(f"{_plural(falls, 'fall alert', 'fall alerts')} recorded")
    if events:
        sentences.append("In the last 24 hours: " + "; ".join(events) + ".")
    if answered:
        sentences.append(
            f"{_plural(answered, 'impact was', 'impacts were')} answered as okay during the voice check-in."
        )

    accepted = int(stats.get('caregiver_provider_accepted_count',0) or 0)
    acknowledged = int(stats.get('caregiver_acknowledged_count',0) or 0)
    if accepted:
        sentences.append(f"The notification provider accepted {_plural(accepted,'alert','alerts')}; acceptance does not confirm receipt by a caregiver.")
    if acknowledged:
        sentences.append(f"A caregiver acknowledged {_plural(acknowledged,'alert','alerts')}.")
    simulated = int(stats.get('simulated_alert_count',0) or 0)
    if simulated:
        sentences.append(f"{_plural(simulated,'alert included','alerts included')} simulated delivery; simulated attempts do not establish real caregiver contact.")

    metrics = stats.get("latest_exam_metrics")
    if metrics:
        sentences.append(
            "Latest motor check: "
            + describe_task_metrics(
                voice_mean_dbfs=metrics.get("voice_mean_dbfs"),
                handwriting_decay_pct=metrics.get("handwriting_opencv_decay_pct"),
                walk_cadence_spm=metrics.get("walk_cadence_spm"),
                walk_fog_count=metrics.get("walk_fog_count"),
            )
            + "."
        )

    if not sentences:
        if stats.get('recorded_event_count',0):
            return "Other observations were logged in the last 24 hours."
        return "Nothing was logged in the last 24 hours."
    return " ".join(sentences)
