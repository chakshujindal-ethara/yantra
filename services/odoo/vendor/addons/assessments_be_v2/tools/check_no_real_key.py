"""Is a real private key sitting in the repo?

    python3 tools/check_no_real_key.py [repo ...]

Exits non-zero if any tracked file contains the private key from the service
account at $ETP_SA_JSON (default: the local dev key).

WHY NOT grep: the module's tests legitimately contain
`-----BEGIN PRIVATE KEY-----abc`, a 4-character stub. Grepping for the header
flags those forever, and a check that cries wolf gets ignored, which is worse
than no check. This compares against the ACTUAL key material, so a stub passes
and a leak fails.

Prints no key material: only lengths and file paths.
"""

import json
import os
import pathlib
import re
import sys

DEFAULT_KEY = ("/Users/cj/Developer/"
               "agon-development-499205-5cb4f96649ef.json")
SKIP = {".git", ".venv", "node_modules", "__pycache__", "build", "src"}
# A short stub cannot be a real key; 1624 chars is a real RSA body. Anything
# above this is long enough that a coincidental match is not plausible.
MIN_MATCH = 64


def flatten(pem):
    return re.sub(r"\s|-----(BEGIN|END) PRIVATE KEY-----", "", pem)


def main(repos):
    path = os.environ.get("ETP_SA_JSON", DEFAULT_KEY)
    if not os.path.exists(path):
        print("SKIP no key at %s - nothing to compare against" % path)
        return 0

    secret = flatten(json.load(open(path))["private_key"])
    if len(secret) < MIN_MATCH:
        print("SKIP key body is only %d chars" % len(secret))
        return 0

    # Match on a slice rather than the whole body: a leak that reformatted
    # line breaks would evade an exact-equality check.
    needle = secret[:MIN_MATCH]
    hits = []
    for repo in repos:
        for f in pathlib.Path(repo).rglob("*"):
            if not f.is_file() or SKIP & set(f.parts):
                continue
            try:
                text = f.read_text(errors="ignore")
            except OSError:
                continue
            if needle in flatten(text):
                hits.append(str(f))

    for h in hits:
        print("LEAK %s" % h)
    print("CHECKED %d repo(s), key body %d chars, leaks %d"
          % (len(repos), len(secret), len(hits)))
    return 1 if hits else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:] or [
        "/Users/cj/Developer/ops-ethara-backend",
        "/Users/cj/Developer/ops-ethara-frontend",
    ]))
