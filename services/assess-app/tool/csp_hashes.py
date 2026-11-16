"""Print the CSP source ('sha256-...') of each inline <script> in a built index.html, one per line.

Run on the built bundle, so the policy allows exactly the inline scripts that shipped and nothing else.
"""

import base64
import hashlib
import re
import sys
from pathlib import Path

INLINE = re.compile(r"<script(?![^>]*\bsrc=)[^>]*>(.*?)</script>", re.S | re.I)


def hashes(html: str) -> list[str]:
    return [
        "'sha256-" + base64.b64encode(hashlib.sha256(body.encode()).digest()).decode() + "'"
        for body in INLINE.findall(html)
    ]


if __name__ == "__main__":
    found = hashes(Path(sys.argv[1]).read_text(encoding="utf-8"))
    if not found:
        sys.exit(f"no inline scripts in {sys.argv[1]}: is this a built index.html?")
    print("\n".join(found))
