"""Provider acceptance and human acknowledgment are separate, incident-bound facts."""

def delivery_evidence(fall, attempts, job=None):
    real = [a for a in attempts if not a.get('simulated') and not any(
        str(a.get(k) or '').startswith(('SM_SIM_', 'CA_SIM_')) for k in ('sms_sid','call_sid'))]
    accepted = any(a.get('sms_sid') or a.get('call_sid') for a in real)
    acknowledged = any(a.get('call_sid') and a.get('acknowledged_at') is not None for a in real)
    simulated = any(a.get('simulated') or any(str(a.get(k) or '').startswith(('SM_SIM_','CA_SIM_')) for k in ('sms_sid','call_sid')) for a in attempts)
    # Legacy SIDs are evidence of provider acceptance, never human acknowledgment.
    legacy_sids = [str(fall.get(k) or '') for k in ('caregiver_sms_sid','caregiver_call_sid')]
    accepted = accepted or any(s and not s.startswith(('SM_SIM_','CA_SIM_')) for s in legacy_sids)
    simulated = simulated or any(s.startswith(('SM_SIM_','CA_SIM_')) for s in legacy_sids)
    status = fall.get('status')
    if status == 'canceled_false_alarm': state = 'canceled'
    elif status == 'suppressed_unworn_drop': state = 'suppressed'
    elif acknowledged: state = 'acknowledged'
    elif accepted: state = 'provider_accepted'
    elif simulated: state = 'simulated'
    elif (job or {}).get('state') == 'exhausted': state = 'exhausted'
    elif status == 'candidate_check_in_pending': state = 'check_in_pending'
    else: state = 'queued'
    return dict(event_uuid=fall['event_uuid'], contact_state=state, provider_accepted=bool(accepted),
        caregiver_acknowledged=bool(acknowledged), simulated=bool(simulated))
