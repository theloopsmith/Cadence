#!/usr/bin/env python3
"""One real SAM 3.1 call through Meta's Responses API, with a sanitized trace.

Usage:
    scripts/sam_smoke.py                      # synthetic red circle, prompt "red circle"
    scripts/sam_smoke.py photo.jpg person coat # your photo, one request per concept

Reads META_API_KEY from backend/.env. Writes docs/verification/sam-live-<date>.json
containing model, concepts, latency, boxes and HTTP status. Never the key or the image.
"""

import asyncio
import json
import sys
import time
from datetime import datetime, timezone
from io import BytesIO
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "backend"))

from PIL import Image, ImageDraw  # noqa: E402

from app.clients.circuit_breaker import RequestDeadlineContext  # noqa: E402
from app.clients.meta_models import MetaModelClient  # noqa: E402
from app.config import settings  # noqa: E402


def synthetic_frame() -> bytes:
    image = Image.new("RGB", (640, 480), "white")
    ImageDraw.Draw(image).ellipse((220, 140, 420, 340), fill=(220, 30, 30))
    buffer = BytesIO()
    image.save(buffer, format="JPEG", quality=90)
    return buffer.getvalue()


async def main(argv: list) -> int:
    if not settings.meta_api_key:
        print("META_API_KEY is not set in backend/.env")
        return 2

    if argv:
        image_bytes = Path(argv[0]).read_bytes()
        concepts = argv[1:] or ["person"]
        source = Path(argv[0]).name
    else:
        image_bytes = synthetic_frame()
        concepts = ["red circle"]
        source = "synthetic 640x480 red circle on white"

    deadline = RequestDeadlineContext()
    started = time.monotonic()
    result = await MetaModelClient().segment_sam_3_1(
        image_bytes=image_bytes, candidate_labels=concepts, deadline=deadline
    )
    wall_ms = int((time.monotonic() - started) * 1000)

    trace = {
        "checked_at_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "endpoint": f"{settings.meta_api_base_url.rstrip('/')}/responses",
        "model": result.get("model"),
        "image_source": source,
        "image_bytes": len(image_bytes),
        "concepts": concepts,
        "sam_verified": result["sam_verified"],
        "failed_labels": result.get("failed_labels", []),
        "errors": result.get("errors", {}),
        "reason": result.get("reason"),
        "wall_ms": wall_ms,
        "records": [
            {"label": m["label"], "object_id": m.get("object_id"), "confidence": m.get("confidence"),
             "box": m.get("box"), "area_ratio": round(m.get("area_ratio", 0), 4)}
            for m in result.get("masks", [])
        ],
    }
    out_dir = ROOT / "docs" / "verification"
    out_dir.mkdir(parents=True, exist_ok=True)
    out = out_dir / f"sam-live-{datetime.now(timezone.utc).date().isoformat()}.json"
    out.write_text(json.dumps(trace, indent=2) + "\n")
    print(json.dumps(trace, indent=2))
    print(f"\nTrace saved to {out.relative_to(ROOT)}")
    return 0 if result["sam_verified"] else 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main(sys.argv[1:])))
