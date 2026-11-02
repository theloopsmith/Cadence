"""Process-local sliding-window quota for ordinary paid inference.

One budget spans routes for each authenticated account (or configured static bearer). Only token hashes
are retained. This is a single-worker guard, not a durable provider spending cap.
Fall check-in transcription has a separate bounded budget, so everyday usage
cannot consume it.
"""
from collections import deque
import hashlib
import json
import math
import threading
import time

from fastapi import Depends, HTTPException, Request

from app.config import settings
from app.security import AuthContext, require_device_writer


class InferenceQuota:
    def __init__(self, clock=time.monotonic, max_keys=4096):
        self.clock = clock
        self.max_keys = max_keys
        self._windows = {}
        self._lock = threading.Lock()

    def consume(self, key, limit):
        with self._lock:
            now = self.clock()
            # Bound memory even if many short-lived authenticated tokens arrive.
            for stale in [k for k, v in self._windows.items() if v[-1] <= now - 60]:
                del self._windows[stale]
            window = self._windows.get(key)
            if window is None:
                if len(self._windows) >= self.max_keys:
                    raise HTTPException(429, "Inference is busy. Please try again shortly.",
                                        headers={"Retry-After": "60"})
                window = self._windows[key] = deque()
            while window and window[0] <= now - 60:
                window.popleft()
            if len(window) >= limit:
                retry = max(1, math.ceil(60 - (now - window[0])))
                raise HTTPException(429, "Too many requests. Please wait before trying again.",
                                    headers={"Retry-After": str(retry)})
            window.append(now)


inference_quota = InferenceQuota()


def consume_inference(request: Request, auth: AuthContext, *, urgent=False):
    # Called only after the writer dependency has validated the bearer token.
    identity = json.dumps([auth.subject, auth.patient_id, auth.role]) if auth.subject else request.headers["authorization"].split()[-1]
    key = ("check-in:" if urgent else "everyday:") + hashlib.sha256(identity.encode()).hexdigest()
    inference_quota.consume(key, 60 if urgent else settings.inference_requests_per_minute)


def require_metered_writer(request: Request, auth: AuthContext = Depends(require_device_writer)):
    consume_inference(request, auth)
    return auth
