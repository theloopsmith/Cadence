"""Accounts, password hashing, and login tokens.

Passwords are hashed with scrypt (standard library) and a per-password salt.
Tokens are HS256 JWTs carrying the role and the bound patient. Repeated
failed logins lock an account for a few minutes.
"""

import base64
import hashlib
import hmac
import secrets
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Dict, Optional

import jwt

from app.config import settings
from app.db import _connect_sync, execute_write_sync, fetch_one_sync

ROLES = {"device_writer", "clinician_reader"}
MIN_PASSWORD_LENGTH = 12
MAX_FAILED_ATTEMPTS = 5
LOCKOUT_SECONDS = 5 * 60
JWT_ALGORITHM = "HS256"
_MIN_SECRET_LENGTH = 32

# scrypt cost: 2^14 iterations, 8-byte blocks, single lane. About 16 MB and
# tens of milliseconds per hash, which is the usual interactive setting.
_SCRYPT_N, _SCRYPT_R, _SCRYPT_P = 2 ** 14, 8, 1

# A random secret for development when none is configured. Tokens issued in one
# run stop working after a restart, which is acceptable outside production.
_dev_secret = secrets.token_urlsafe(48)


class AuthError(Exception):
    """A login that must be refused. `locked` distinguishes rate limiting."""

    def __init__(self, message: str, locked: bool = False):
        super().__init__(message)
        self.locked = locked


# ---------------------------------------------------------------- passwords
def _b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode("ascii").rstrip("=")


def _unb64(text: str) -> bytes:
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def hash_password(password: str) -> str:
    if len(password) < MIN_PASSWORD_LENGTH:
        raise ValueError(f"Passwords must be at least {MIN_PASSWORD_LENGTH} characters.")
    salt = secrets.token_bytes(16)
    digest = hashlib.scrypt(
        password.encode("utf-8"), salt=salt, n=_SCRYPT_N, r=_SCRYPT_R, p=_SCRYPT_P, dklen=32
    )
    return f"scrypt${_SCRYPT_N}${_SCRYPT_R}${_SCRYPT_P}${_b64(salt)}${_b64(digest)}"


def verify_password(password: str, stored: str) -> bool:
    try:
        scheme, n, r, p, salt, digest = stored.split("$")
        if scheme != "scrypt":
            return False
        expected = _unb64(digest)
        actual = hashlib.scrypt(
            password.encode("utf-8"), salt=_unb64(salt), n=int(n), r=int(r), p=int(p), dklen=len(expected)
        )
    except (ValueError, TypeError):
        return False
    return hmac.compare_digest(actual, expected)


# A fixed hash to check against when the username does not exist, so an
# unknown user takes as long to refuse as a wrong password.
_DUMMY_HASH = hash_password("unused-placeholder-password")


# ---------------------------------------------------------------- accounts
def create_user_sync(username: str, password: str, role: str, patient_id: str) -> None:
    if role not in ROLES:
        raise ValueError(f"Unknown role {role!r}.")
    username = username.strip()
    if not username:
        raise ValueError("A username is required.")
    execute_write_sync(
        """
        INSERT INTO users (username, password_hash, role, patient_id, created_at_utc)
        VALUES (?, ?, ?, ?, ?)
        """,
        (username, hash_password(password), role, patient_id, datetime.now(timezone.utc).isoformat()),
    )


# ---------------------------------------------------------------- lockout
def reset_lockouts() -> None:
    """Explicit test/operator reset; never called during server startup."""
    execute_write_sync("DELETE FROM login_attempts")


def _locked() -> AuthError:
    return AuthError("Too many tries. Please wait a few minutes and try again.", locked=True)


def _reserve_attempt(username: str) -> str:
    """Reserve before hashing so parallel requests cannot exceed the budget.

    A crashed or abandoned verification consumes its reservation. Hashing runs
    outside the write transaction so it cannot hold up fall-event persistence.
    Unknown usernames use the same budget and store only a fixed-size digest.
    """
    key = hashlib.sha256(username.encode("utf-8")).hexdigest()
    revision = secrets.token_hex(16)
    conn = _connect_sync()
    try:
        conn.execute("PRAGMA synchronous=FULL")
        conn.execute("BEGIN IMMEDIATE")
        now = time.time()
        conn.execute("DELETE FROM login_attempts WHERE expires_at <= ?", (now,))
        prior = conn.execute("SELECT * FROM login_attempts WHERE username_hash=?", (key,)).fetchone()
        if prior and prior["locked_until"] > now:
            raise _locked()
        attempts = (prior["attempts"] if prior else 0) + 1
        conn.execute("""INSERT OR REPLACE INTO login_attempts
            (username_hash,attempts,locked_until,expires_at,revision) VALUES(?,?,?,?,?)""",
            (key, attempts, now + LOCKOUT_SECONDS if attempts >= MAX_FAILED_ATTEMPTS else 0,
             now + LOCKOUT_SECONDS, revision))
        conn.commit()
        return revision
    except BaseException:
        conn.rollback()
        raise
    finally:
        conn.close()


def _record_success(username: str, revision: str) -> None:
    key = hashlib.sha256(username.encode("utf-8")).hexdigest()
    conn = _connect_sync()
    try:
        conn.execute("PRAGMA synchronous=FULL")
        conn.execute("BEGIN IMMEDIATE")
        row = conn.execute("SELECT * FROM login_attempts WHERE username_hash=?", (key,)).fetchone()
        # An older successful check must not clear failures from newer requests.
        if row and row["revision"] != revision and row["locked_until"] > time.time():
            raise _locked()
        conn.execute("DELETE FROM login_attempts WHERE username_hash=? AND revision=?", (key, revision))
        conn.commit()
    except BaseException:
        conn.rollback()
        raise
    finally:
        conn.close()


# ---------------------------------------------------------------- login
@dataclass(frozen=True)
class IssuedToken:
    access_token: str
    expires_in: int
    role: str


def authenticate_sync(username: str, password: str) -> IssuedToken:
    username = username.strip()
    revision = _reserve_attempt(username)
    row = fetch_one_sync(
        "SELECT username, password_hash, role, patient_id FROM users WHERE username = ?", (username,)
    )
    stored = row["password_hash"] if row else _DUMMY_HASH
    if not verify_password(password, stored) or row is None:
        raise AuthError("That username or password didn't match.")
    _record_success(username, revision)
    ttl = (
        settings.jwt_device_ttl_days * 24 * 3600
        if row["role"] == "device_writer"
        else settings.jwt_access_ttl_minutes * 60
    )
    return IssuedToken(
        access_token=issue_token(row["username"], row["role"], row["patient_id"], ttl_seconds=ttl),
        expires_in=ttl,
        role=row["role"],
    )


# ---------------------------------------------------------------- tokens
def _signing_secret() -> str:
    return settings.jwt_secret or _dev_secret


def issue_token(subject: str, role: str, patient_id: str, ttl_seconds: Optional[int] = None) -> str:
    now = int(time.time())
    ttl = settings.jwt_access_ttl_minutes * 60 if ttl_seconds is None else ttl_seconds
    claims = {"sub": subject, "role": role, "pid": patient_id, "iat": now, "exp": now + ttl}
    return jwt.encode(claims, _signing_secret(), algorithm=JWT_ALGORITHM)


def decode_token(token: str) -> Optional[Dict[str, str]]:
    """Claims for a valid token, or None. Only HS256 with our secret is accepted."""
    try:
        claims = jwt.decode(
            token,
            _signing_secret(),
            algorithms=[JWT_ALGORITHM],
            options={"require": ["exp", "sub", "role", "pid"]},
        )
    except jwt.PyJWTError:
        return None
    if claims.get("role") not in ROLES:
        return None
    return claims


# ---------------------------------------------------------------- startup
def validate_security_settings() -> None:
    """Refuse to run a production server with development defaults."""
    if not settings.is_production:
        return
    if len(settings.jwt_secret) < _MIN_SECRET_LENGTH:
        raise RuntimeError(
            f"JWT_SECRET must be set to at least {_MIN_SECRET_LENGTH} characters in production."
        )
    # A production server exists to reach a caregiver. Missing delivery
    # configuration must fail here, not fifteen retries after a real fall.
    missing = [
        name.upper()
        for name in ("twilio_account_sid", "twilio_auth_token", "twilio_from_phone", "caregiver_primary_phone")
        if not getattr(settings, name)
    ]
    if missing:
        raise RuntimeError(f"Production requires caregiver dispatch settings: {', '.join(missing)}.")
    if not settings.public_webhook_base_url.lower().startswith("https://"):
        raise RuntimeError("PUBLIC_WEBHOOK_BASE_URL must be https in production so Twilio callbacks can be verified.")
    if settings.demo_mode_enabled:
        raise RuntimeError("DEMO_MODE must be off in production.")
    if settings.static_tokens_enabled:
        raise RuntimeError("ALLOW_STATIC_TOKENS must be off in production.")
