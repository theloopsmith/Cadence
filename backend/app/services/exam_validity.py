"""Validity travels with each task. Old numeric defaults cannot establish measurement."""
TASK_FIELDS = {
    'voice': ('voice_mean_dbfs','voice_stability_db'),
    'handwriting': ('handwriting_opencv_decay_pct','handwriting_sam_decay_pct'),
    'walk': ('walk_cadence_spm','walk_mean_fi','walk_fog_count'),
}


def measured_exam(row):
    from app.responses import observation_projection
    result = observation_projection(dict(row))
    source = result.setdefault("measurement_source", "legacy_unverified")
    evidence = {}
    for task, fields in TASK_FIELDS.items():
        status = result.get(task+'_status', 'legacy_unverified')
        if source == 'simulated' and status in {'measured', 'simulated'}:
            status = 'simulated'
        elif source == 'legacy_unverified' or (status == 'simulated' and source != 'simulated'):
            status = 'legacy_unverified'
        if status not in {'measured', 'simulated'}:
            for field in fields:
                result[field] = None
        result[task+'_status'] = status
        evidence[task] = {'status': status, 'measurement_source': source}
    result['task_evidence'] = evidence
    complete = all(e['status'] in {'measured','simulated'} for e in evidence.values())
    if 'clinical_summary' in result:
        from app.services.plain_language import describe_task_metrics, exam_source_words
        result['clinical_summary'] = 'Home motor check (' + exam_source_words(source) + '): ' + describe_task_metrics(
            result.get('voice_mean_dbfs'), result.get('handwriting_opencv_decay_pct'),
            result.get('walk_cadence_spm'), result.get('walk_fog_count')) + '.'
    result['complete'] = complete
    return result
