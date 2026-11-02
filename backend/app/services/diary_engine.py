"""Factual event buckets; no medication-state or symptom classification."""
from datetime import datetime, timedelta, timezone
from typing import Any, Dict, List, Optional


def _parse_utc(value: str) -> Optional[datetime]:
    try:
        result = datetime.fromisoformat(str(value).replace('Z', '+00:00'))
        if result.tzinfo is None:
            result = result.replace(tzinfo=timezone.utc)
        return result.astimezone(timezone.utc)
    except (ValueError, TypeError):
        return None


def build_24h_diary_timeline(
    fog_rows: List[Dict[str, Any]], fall_rows: List[Dict[str, Any]],
    med_rows: List[Dict[str, Any]], writing_rows: List[Dict[str, Any]],
    voice_rows: List[Dict[str, Any]], exam_rows: List[Dict[str, Any]],
    reference_end_utc: Optional[datetime] = None,
    other_rows: Optional[List[Dict[str, Any]]] = None,
) -> Dict[str, Any]:
    end = reference_end_utc or datetime.now(timezone.utc)
    if end.tzinfo is None:
        end = end.replace(tzinfo=timezone.utc)
    end = end.astimezone(timezone.utc)
    start = end - timedelta(hours=24)

    def window(rows):
        return [r for r in rows if (dt := _parse_utc(r.get('timestamp_utc', ''))) and start <= dt < end]

    groups = [window(rows) for rows in (fog_rows, fall_rows, med_rows, writing_rows, voice_rows, exam_rows, other_rows or [])]
    doses = sorted(dt for r in groups[2] if r.get('event_type') == 'dose_taken'
                   if (dt := _parse_utc(r['timestamp_utc'])))
    buckets = []
    for index in range(48):
        begin = start + timedelta(minutes=30 * index)
        finish = begin + timedelta(minutes=30)
        fogs, all_falls, meds, writing, voice, exams, others = [
            [r for r in rows if begin <= _parse_utc(r['timestamp_utc']) < finish] for rows in groups
        ]
        falls = [r for r in all_falls if r.get('status') not in {
            'canceled_false_alarm', 'suppressed_unworn_drop', 'candidate_check_in_pending'}]
        prior = [d for d in doses if d <= finish and (finish-d).total_seconds() <= 12*3600]
        count = sum(map(len, (fogs, all_falls, meds, writing, voice, exams, others)))
        buckets.append({
            'bucket_start_utc': begin.isoformat(), 'bucket_end_utc': finish.isoformat(),
            'label_hhmm': begin.strftime('%H:%M'),
            'observation_status': 'events_logged' if count else 'no_observations',
            'event_count': count, 'check_in_logged': bool(all_falls),
            'dose_logged_count': sum(r.get('event_type') == 'dose_taken' for r in meds),
            'meal_logged_count': sum(r.get('event_type') == 'meal_logged' for r in meds),
            'scene_check_count': len(others), 'monitoring_coverage': 'unknown',
            'fog_count': len(fogs) + sum(int(ex.get('walk_fog_count') or 0) for ex in exams),
            'fall_occurred': bool(falls), 'has_exam': bool(exams),
            'exam_complete': any(ex.get('complete', False) for ex in exams),
            'minutes_since_last_dose': int((finish-prior[-1]).total_seconds()//60) if prior else None,
        })
    return {'buckets': buckets}
