"""Accounts, password hashing, and login tokens.

Passwords are hashed with scrypt (standard library) and a per-password salt.
Tokens are HS256 JWTs carrying the role and the bound patient. Repeated
failed logins lock an account for a few minutes.
"""

import base64
import hashlib
import hmac
import secrets
import threading
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Dict, Optional, Tuple

import jwt

from app.config import settings
from app.db import execute_write_sync, fetch_one_sync

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
_failures: Dict[str, Tuple[int, float]] = {}
_lock = threading.Lock()


def reset_lockouts() -> None:
    with _lock:
        _failures.clear()


def _check_lockout(username: str) -> None:
    with _lock:
        count, locked_until = _failures.get(username, (0, 0.0))
    if locked_until > time.monotonic():
        raise AuthError("Too many tries. Please wait a few minutes and try again.", locked=True)


def _record_failure(username: str) -> None:
    with _lock:
        count, _ = _failures.get(username, (0, 0.0))
        count += 1
        locked_until = time.monotonic() + LOCKOUT_SECONDS if count >= MAX_FAILED_ATTEMPTS else 0.0
        _failures[username] = (count, locked_until)


def _record_success(username: str) -> None:
    with _lock:
        _failures.pop(username, None)


# ---------------------------------------------------------------- login
@dataclass(frozen=True)
class IssuedToken:
    access_token: str
    expires_in: int
    role: str


def authenticate_sync(username: str, password: str) -> IssuedToken:
    username = username.strip()
    _check_lockout(username)
    row = fetch_one_sync(
        "SELECT username, password_hash, role, patient_id FROM users WHERE username = ?", (username,)
    )
    stored = row["password_hash"] if row else _DUMMY_HASH
    if not verify_password(password, stored) or row is None:
        _record_failure(username)
        raise AuthError("That username or password didn't match.")
    _record_success(username)
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
