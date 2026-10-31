from datetime import datetime, timezone
import asyncio
from typing import Dict, Optional, Tuple
from urllib.parse import urlencode
from xml.sax.saxutils import escape

from app.config import settings


def mask_phone(phone: str) -> str:
    cleaned = "".join(ch for ch in phone if ch.isdigit() or ch == "+")
    if len(cleaned) <= 4:
        return "***"
    return f"***-***-{cleaned[-4:]}"


def _readable_time(timestamp_utc: str) -> str:
    """A caregiver reads this on a phone; an ISO string with microseconds is not for them."""
    try:
        when = datetime.fromisoformat(str(timestamp_utc).replace("Z", "+00:00"))
        if when.tzinfo is None:
            when = when.replace(tzinfo=timezone.utc)
        return when.astimezone(timezone.utc).strftime("%H:%M UTC on %b %d")
    except ValueError:
        return "an unknown time"


class TwilioEscalationClient:
    """
    Twilio SMS (with CoreLocation GPS link) + Automated Voice Call (<Gather numDigits='1'>)
    + Post-Cancel All-Clear SMS dispatcher.
    """

    def format_fall_sms_body(
        self,
        peak_impact_g: float,
        timestamp_utc: str,
        latitude: Optional[float] = None,
        longitude: Optional[float] = None,
    ) -> str:
        body = (
            f"CADENCE EMERGENCY FALL ALERT: Hard impact ({peak_impact_g:.1f}g) detected "
            f"at {_readable_time(timestamp_utc)}. The wearer did not answer the check-in."
        )
        if latitude is not None and longitude is not None:
            body += f" GPS Location: https://maps.google.com/?q={latitude:.6f},{longitude:.6f}"
        return body

    def build_gather_twiml(self, event_uuid: str, attempt_id: Optional[str] = None, test_only: bool = False) -> str:
        gather_url = (
            f"{settings.public_webhook_base_url.rstrip('/')}"
            "/api/v1/webhooks/twilio/gather?" + urlencode({"event_uuid": event_uuid, **({"attempt_id": attempt_id} if attempt_id else {})})
        )
        gather_url = escape(gather_url, {'"': '&quot;'})
        message = ("This is a scheduled Cadence test only. There is no emergency. " if test_only else "Fall alert from Cadence accessibility companion. ")
        return (
            '<?xml version="1.0" encoding="UTF-8"?>'
            "<Response>"
            f'<Gather numDigits="1" timeout="20" action="{gather_url}" method="POST">'
            "<Say voice=\"Polly.Joanna\">"
            f"{message}"
            "Press 1 now to acknowledge this alert and confirm you are responding."
            "</Say>"
            "</Gather>"
            "<Say voice=\"Polly.Joanna\">No key was pressed. Escalating alert.</Say>"
            "</Response>"
        )

    async def dispatch_sms_and_call(
        self,
        to_phone: str,
        event_uuid: str,
        peak_impact_g: float,
        timestamp_utc: str,
        latitude: Optional[float] = None,
        longitude: Optional[float] = None,
        attempt_id: Optional[str] = None,
        test_only: bool = False,
    ) -> Dict[str, str]:
        """Dispatches SMS + Voice call via Twilio REST API (or simulated SIDs in test/dev)."""
        sms_body = self.format_fall_sms_body(
            peak_impact_g=peak_impact_g,
            timestamp_utc=timestamp_utc,
            latitude=latitude,
            longitude=longitude,
        )
        if test_only:
            sms_body = "CADENCE SCHEDULED TEST ONLY: No emergency. Please answer the test call and press 1 to verify acknowledgment."
        twiml = self.build_gather_twiml(event_uuid, attempt_id, test_only)

        if not (
            settings.twilio_account_sid
            and settings.twilio_auth_token
            and settings.twilio_from_phone
            and to_phone
        ):
            if settings.is_production or not settings.demo_mode_enabled:
                return {"sms_sid": "", "call_sid": "", "sms_body": sms_body,
                        "twiml": twiml, "delivery_status": "unconfigured"}
            return {
                "sms_sid": f"SM_SIM_{event_uuid[:8]}",
                "call_sid": f"CA_SIM_{event_uuid[:8]}",
                "sms_body": sms_body,
                "twiml": twiml,
                "delivery_status": "queued",
            }

        sms_sid, call_sid, delivery_status = await asyncio.to_thread(
            _place_sms_and_call,
            to_phone,
            sms_body,
            twiml,
            (
                f"{settings.public_webhook_base_url.rstrip('/')}"
                "/api/v1/webhooks/twilio/status?" + urlencode({"event_uuid": event_uuid, **({"attempt_id": attempt_id} if attempt_id else {})})
            ),
        )
        return {
            "sms_sid": sms_sid,
            "call_sid": call_sid,
            "sms_body": sms_body,
            "twiml": twiml,
            "delivery_status": delivery_status,
        }

    async def send_all_clear_sms(
        self,
        to_phone: str,
        event_uuid: str,
    ) -> Dict[str, str]:
        """Sends an automated All-Clear SMS when a dispatched fall alert is canceled on-device."""
        body = (
            "CADENCE ALL-CLEAR: The fall alert was canceled on the patient's device. "
            "No further automated calls will be placed."
        )
        if not (
            settings.twilio_account_sid
            and settings.twilio_auth_token
            and settings.twilio_from_phone
            and to_phone
        ):
            if settings.is_production or not settings.demo_mode_enabled:
                return {"sms_sid": "", "body": body, "delivery_status": "unconfigured"}
            return {
                "sms_sid": f"SM_CLEAR_{event_uuid[:8]}",
                "body": body,
                "delivery_status": "delivered",
            }
        try:
            from twilio.rest import Client

            client = Client(settings.twilio_account_sid, settings.twilio_auth_token)
            msg = await asyncio.to_thread(client.messages.create,
                body=body,
                from_=settings.twilio_from_phone,
                to=to_phone,
            )
            return {"sms_sid": msg.sid, "body": body, "delivery_status": "delivered"}
        except Exception:
            return {"sms_sid": "", "body": body, "delivery_status": "failed"}


def _place_sms_and_call(
    to_phone: str,
    sms_body: str,
    twiml: str,
    status_callback: str,
) -> Tuple[str, str, str]:
    """Places SMS and the voice call independently. A dead SMS path must not skip the call."""
    from twilio.rest import Client

    from twilio.http.http_client import TwilioHttpClient
    client = Client(settings.twilio_account_sid, settings.twilio_auth_token, http_client=TwilioHttpClient(timeout=5))
    sms_sid = ""
    call_sid = ""
    errors = []
    try:
        sms_msg = client.messages.create(
            body=sms_body,
            from_=settings.twilio_from_phone,
            to=to_phone,
        )
        sms_sid = sms_msg.sid or ""
    except Exception as exc:
        errors.append(f"sms:{exc}")
    try:
        call_msg = client.calls.create(
            twiml=twiml,
            from_=settings.twilio_from_phone,
            to=to_phone,
            status_callback=status_callback,
            status_callback_method="POST",
        )
        call_sid = call_msg.sid or ""
    except Exception as exc:
        errors.append(f"call:{exc}")
    if sms_sid and call_sid:
        delivery_status = "queued"
    elif sms_sid or call_sid:
        delivery_status = "partial"
    else:
        delivery_status = "failed:" + (errors[0] if errors else "unknown")
    return sms_sid, call_sid, delivery_status


twilio_client = TwilioEscalationClient()
