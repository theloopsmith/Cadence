import hmac
import secrets
from dataclasses import dataclass
from typing import Optional

from fastapi import Depends, HTTPException, Request, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from app.auth import decode_token
from app.config import settings

bearer_scheme = HTTPBearer(auto_error=False)


@dataclass(frozen=True)
class AuthContext:
    role: str          # "device_writer" | "clinician_reader"
    patient_id: str    # Bound patient_id for tenant isolation


def get_auth_context(
    credentials: Optional[HTTPAuthorizationCredentials] = Depends(bearer_scheme),
) -> AuthContext:
    """Validates Bearer token and resolves role + bound patient_id."""
    if credentials is None or not credentials.credentials:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Missing Authorization Bearer token",
        )
    token = credentials.credentials
    claims = decode_token(token)
    if claims is not None:
        return AuthContext(role=claims["role"], patient_id=claims["pid"])

    if settings.static_tokens_enabled:
        if secrets.compare_digest(token, settings.cadence_device_token):
            return AuthContext(
                role="device_writer",
                patient_id=settings.cadence_default_patient_id,
            )
        if secrets.compare_digest(token, settings.cadence_clinician_token):
            return AuthContext(
                role="clinician_reader",
                patient_id=settings.cadence_default_patient_id,
            )
    raise HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Please sign in again.",
    )


def require_demo_mode() -> None:
    """Demo-only endpoints and inputs. Off in production."""
    if not settings.demo_mode_enabled:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Demo data is turned off on this server.",
        )


def reject_simulated_inputs(**fields: object) -> None:
    """`simulated_*` request fields stand in for camera output in tests and demos only."""
    if settings.demo_mode_enabled:
        return
    if any(value is not None for value in fields.values()):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Simulated inputs are only accepted in demo mode. Send a photo instead.",
        )


def require_device_writer(
    ctx: AuthContext = Depends(get_auth_context),
) -> AuthContext:
    """Enforces device_writer role for event ingestion, fall cancel, and patient data wipe."""
    if ctx.role != "device_writer":
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Clinician reader token is read-only; device_writer role required",
        )
    return ctx


def require_any_authenticated_role(
    ctx: AuthContext = Depends(get_auth_context),
) -> AuthContext:
    """Allows either device_writer or clinician_reader (e.g., GET /api/v1/report/neurologist)."""
    return ctx


async def verify_twilio_signature(request: Request) -> dict:
    """
    Validates X-Twilio-Signature header on incoming Twilio webhooks (/status and /gather).
    Returns parsed form parameters if valid, or raises 403 Forbidden.
    """
    form_data = await request.form()
    params = {k: str(v) for k, v in form_data.items()}

    # If no auth token is configured in local dev/test without signature enforcement,
    # still require X-Twilio-Signature when twilio_auth_token is non-empty.
    if not settings.twilio_auth_token:
        if settings.is_production or not settings.demo_mode_enabled:
            raise HTTPException(status_code=503, detail="Caregiver callback verification is unavailable.")
        return params

    signature = request.headers.get("X-Twilio-Signature", "")
    if not signature:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Missing X-Twilio-Signature header",
        )

    try:
        from twilio.request_validator import RequestValidator

        validator = RequestValidator(settings.twilio_auth_token)
        # Reconstruct canonical webhook URL or compare against public_webhook_base_url
        full_url = str(request.url)
        configured_url = f"{settings.public_webhook_base_url.rstrip('/')}{request.url.path}"
        if request.url.query:
            configured_url = f"{configured_url}?{request.url.query}"

        is_valid = validator.validate(full_url, params, signature) or validator.validate(
            configured_url, params, signature
        )
    except Exception:
        # Fallback HMAC-SHA1 per Twilio spec if twilio package validator raises
        full_url = str(request.url)
        s = full_url + "".join(f"{k}{params[k]}" for k in sorted(params.keys()))
        import base64
        import hashlib

        mac = hmac.new(
            settings.twilio_auth_token.encode("utf-8"),
            s.encode("utf-8"),
            hashlib.sha1,
        )
        computed = base64.b64encode(mac.digest()).decode("utf-8")
        is_valid = secrets.compare_digest(computed, signature)

    if not is_valid:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Invalid X-Twilio-Signature",
        )
    return params
