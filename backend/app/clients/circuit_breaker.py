import time
from dataclasses import dataclass, field
from typing import Dict, Tuple


@dataclass
class RequestDeadlineContext:
    """Enforces a hard 4.0-second total wall-clock budget across chained cloud calls."""

    total_budget_sec: float = 4.0
    started_at: float = field(default_factory=time.monotonic)

    def remaining_sec(self) -> float:
        return max(0.0, self.total_budget_sec - (time.monotonic() - self.started_at))

    def timeout_for_stage(
        self, stage_max_sec: float, min_viable_sec: float = 0.35
    ) -> float:
        rem = self.remaining_sec()
        if rem < min_viable_sec:
            raise TimeoutError(
                f"Request deadline exhausted ({rem:.2f}s remaining < {min_viable_sec:.2f}s)"
            )
        return min(stage_max_sec, rem)


class PerModelCircuitBreakerRegistry:
    """
    Tracks 3-strike circuit breakers keyed by (provider, model_id) so a transient
    SAM 3.1 slowdown never trips Muse Voice TTS or Muse Transcribe STT.
    """

    def __init__(self, failure_threshold: int = 3, cooldown_sec: float = 60.0):
        self.failure_threshold = failure_threshold
        self.cooldown_sec = cooldown_sec
        self._failures: Dict[Tuple[str, str], int] = {}
        self._opened_until: Dict[Tuple[str, str], float] = {}

    def is_available(self, provider: str, model_id: str) -> bool:
        key = (provider, model_id)
        until = self._opened_until.get(key, 0.0)
        if until > time.monotonic():
            return False
        if until > 0.0:
            self._opened_until.pop(key, None)
            self._failures[key] = 0
        return True

    def record_success(self, provider: str, model_id: str) -> None:
        key = (provider, model_id)
        self._failures[key] = 0
        self._opened_until.pop(key, None)

    def record_failure(self, provider: str, model_id: str) -> None:
        key = (provider, model_id)
        count = self._failures.get(key, 0) + 1
        self._failures[key] = count
        if count >= self.failure_threshold:
            self._opened_until[key] = time.monotonic() + self.cooldown_sec

    def reset_all(self) -> None:
        self._failures.clear()
        self._opened_until.clear()


circuit_breakers = PerModelCircuitBreakerRegistry()
