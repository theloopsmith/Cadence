#!/usr/bin/env python3
"""Check local links in the maintained README/docs without network requests."""
from pathlib import Path
import re
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[1]
broken = []
for source in [ROOT / 'README.md', *sorted((ROOT / 'docs').rglob('*.md'))]:
    for match in re.finditer(r'!?\[[^\]]*\]\((<[^>]+>|[^)\s]+)(?:\s+"[^"]*")?\)', source.read_text()):
        target = match.group(1).strip('<>')
        url = urlsplit(target)
        if url.scheme or url.netloc or not url.path:
            continue
        path = source.parent / unquote(url.path)
        if not path.exists():
            broken.append(f'{source.relative_to(ROOT)}: {target}')
if broken:
    raise SystemExit('Broken documentation links:\n' + '\n'.join(broken))
print('Maintained documentation links resolve.')
