"""Reads SAM 3.1's special-token output text.

The wire grammar (meta-models/meta-sam, protocol/sam3.md): one line per frame,
`<Nf>` then comma-separated segments of `<id><|box;...|><|mask;...|>`. Fields are
`;`-separated `key=value` pairs read by name. A missing `c` means no confidence,
not zero. Masks are left encoded; the box gives the frame fraction the rest of
the pipeline needs.
"""

import math
import re
from typing import Any, Dict, List, Optional

_FRAME = re.compile(r"^<(\d+)f(?:;[^>]*)?>")
_TOKEN = re.compile(r"<\|([A-Za-z][A-Za-z0-9_.\-]*)(?:;([^|]*?))?\|>")
_INT = re.compile(r"^-?\d+$")
_UINT = re.compile(r"^\d+$")
_CONF = re.compile(r"^-?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?$")


def _fields(body: Optional[str]) -> Optional[Dict[str, str]]:
    """Splits on `;` only; the mask payload may contain `=` and letters."""
    out: Dict[str, str] = {}
    for raw in (body or "").split(";"):
        part = raw.strip()
        if not part:
            continue
        key, sep, value = part.partition("=")
        key = key.strip()
        value = value.strip() if sep else ""
        if key == "c" and key in out:
            # A repeated c is ignored, the record kept.
            out[key] = ""
            continue
        if key in out and key != "c":
            return None
        out[key] = value
    return out


def _confidence(fields: Dict[str, str]) -> Optional[float]:
    raw = fields.get("c")
    if raw is None or not _CONF.match(raw):
        return None
    try:
        value = float(raw)
    except ValueError:
        return None
    if not math.isfinite(value) or value < 0 or value > 1:
        return None
    return 0.0 if value == 0 else value


def _parse_segment(segment: str, label: str) -> Optional[Dict[str, Any]]:
    match = re.match(r"^(\d+)", segment)
    if not match:
        return None
    object_id = match.group(1)
    rest = segment[match.end():]

    box: Optional[Dict[str, str]] = None
    mask_seen = False
    pos = 0
    for token in _TOKEN.finditer(rest):
        if rest[pos:token.start()].strip():
            return None  # text between tokens
        pos = token.end()
        name, fields = token.group(1), _fields(token.group(2))
        if fields is None:
            return None
        if name == "box":
            if box is not None:
                return None
            box = fields
        elif name == "mask":
            if mask_seen:
                return None
            mask_seen = True
    if rest[pos:].strip() or box is None or not mask_seen:
        return None

    try:
        x1, y1, x2, y2 = (int(box[k]) for k in ("x1", "y1", "x2", "y2"))
        w, h = int(box["w"]), int(box["h"])
    except (KeyError, ValueError):
        return None
    for k in ("x1", "y1", "x2", "y2"):
        if not _INT.match(box[k]):
            return None
    if not (_UINT.match(box["w"]) and _UINT.match(box["h"])) or w <= 0 or h <= 0:
        return None
    if x2 < x1 or y2 < y1 or x1 < 0 or y1 < 0 or x2 >= w or y2 >= h:
        return None

    area_px = (x2 - x1 + 1) * (y2 - y1 + 1)
    return {
        "label": label,
        "object_id": object_id,
        "confidence": _confidence(box),
        "box": {"x1": x1, "y1": y1, "x2": x2, "y2": y2, "w": w, "h": h},
        "area_px": area_px,
        "area_ratio": area_px / (w * h),
    }


def _split_segments(body: str) -> List[str]:
    """Splits on commas that sit between tokens; the mask payload carries commas too."""
    segments: List[str] = []
    current: List[str] = []
    i = 0
    while i < len(body):
        if body.startswith("<|", i):
            end = body.find("|>", i + 2)
            if end < 0:
                current.append(body[i:])
                break
            current.append(body[i:end + 2])
            i = end + 2
        elif body[i] == ",":
            segments.append("".join(current))
            current = []
            i += 1
        else:
            current.append(body[i])
            i += 1
    segments.append("".join(current))
    return segments


def parse_sam_output_text(text: str, label: str) -> List[Dict[str, Any]]:
    """Image records only (frame 0). A malformed segment drops its whole line."""
    records: List[Dict[str, Any]] = []
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        frame = _FRAME.match(line)
        if not frame or frame.group(1) != "0":
            continue
        body = line[frame.end():]
        if not body.strip():
            continue  # bare frame header is malformed
        line_records: List[Dict[str, Any]] = []
        ok = True
        for segment in _split_segments(body):
            segment = segment.strip()
            if not segment:
                continue
            record = _parse_segment(segment, label)
            if record is None:
                ok = False
                break
            line_records.append(record)
        if ok:
            records.extend(line_records)
    return records


def output_text_from_response(payload: Dict[str, Any]) -> str:
    """The Responses API may give `output_text` directly or inside `output[].content[]`."""
    direct = payload.get("output_text")
    if isinstance(direct, str):
        return direct
    parts: List[str] = []
    for item in payload.get("output", []) or []:
        for part in item.get("content", []) or []:
            if part.get("type") == "output_text" and isinstance(part.get("text"), str):
                parts.append(part["text"])
    return "".join(parts)
