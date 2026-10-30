"""Validity travels with each task. Old numeric defaults cannot establish measurement."""
TASK_FIELDS = {
    'voice': ('voice_mean_dbfs','voice_stability_db','voice_score'),
    'handwriting': ('handwriting_opencv_decay_pct','handwriting_sam_decay_pct','handwriting_score'),
    'walk': ('walk_cadence_spm','walk_mean_fi','walk_fog_count','gait_score'),
}


def measured_exam(row):
    result = dict(row)
    for task, fields in TASK_FIELDS.items():
        if result.get(task+'_status', 'legacy_unverified') != 'measured':
            for field in fields:
                result[field] = None
    complete = all(result.get(task+'_status') == 'measured' for task in TASK_FIELDS)
    if not complete:
        for field in ('composite_motor_score','medication_state_label','symptom_burden_score'):
            result[field] = None
    if 'clinical_summary' in result:
        from app.services.plain_language import describe_task_metrics
        result['clinical_summary'] = 'Home motor check: ' + describe_task_metrics(
            result.get('voice_mean_dbfs'), result.get('handwriting_opencv_decay_pct'),
            result.get('walk_cadence_spm'), result.get('walk_fog_count')) + '.'
    result['complete'] = complete
    return result
