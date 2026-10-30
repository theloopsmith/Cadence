"""Which logged dose was in effect at a meal or an exam."""

from datetime import datetime, timezone
from typing import Iterable, Optional

from app.db import fetch_all


def parse_utc(value: str) -> datetime:
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def latest_dose_at_or_before(timestamps: Iterable[str], event_iso: str) -> Optional[str]:
    """
    The dose a clinician would call current: the latest one taken at or before
    the event. A dose logged later in the day, or uploaded first by the offline
    queue, is not yet in effect.
    """
    event = parse_utc(event_iso)
    best_raw: Optional[str] = None
    best_at: Optional[datetime] = None
    for raw in timestamps:
        try:
            taken = parse_utc(raw)
        except ValueError:
            continue
        if taken <= event and (best_at is None or taken > best_at):
            best_at = taken
            best_raw = raw
    return best_raw


async def dose_timestamp_at_or_before(patient_id: str, event_iso: str) -> Optional[str]:
    rows = await fetch_all(
        """
        SELECT timestamp_utc FROM medication_logs
        WHERE patient_id = ? AND event_type = 'dose_taken'
          AND event_uuid NOT IN (
              SELECT retracted_event_uuid FROM medication_retractions WHERE patient_id = ?
          )
        """,
        (patient_id, patient_id),
    )
    return latest_dose_at_or_before(
        (str(row["timestamp_utc"]) for row in rows),
        event_iso,
    )
