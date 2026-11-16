"""The Keycloak realm as one production-shaped base (`deployment/keycloak/yantra-realm.json`) plus an overlay per
environment (`deployment/keycloak/overlays/<env>.json`). `yantra realm-render` writes base + local overlay to
`deployment/local/keycloak/yantra-realm.json`, the file the rig imports; `--check` fails when that file has drifted,
so nobody edits the generated file by hand.

Merge rules: objects merge key by key; a list of objects that all carry one of the identity keys (`name`,
`clientId`, `username`, `alias`) merges item by item on that key, items new to the overlay appended; any other value
in the overlay replaces the base's."""

import json
from pathlib import Path
from typing import Any

IDENTITY_KEYS = ("name", "clientId", "username", "alias")
ROOT = Path(__file__).resolve().parents[3]
BASE = Path("deployment/keycloak/yantra-realm.json")
OVERLAYS = Path("deployment/keycloak/overlays")
LOCAL_OUTPUT = Path("deployment/local/keycloak/yantra-realm.json")


def _identity(items: list[Any]) -> str | None:
    if not items or not all(isinstance(i, dict) for i in items):
        return None
    for key in IDENTITY_KEYS:
        if all(key in i for i in items):
            return key
    return None


def merge(base: Any, overlay: Any) -> Any:
    if isinstance(base, dict) and isinstance(overlay, dict):
        out = dict(base)
        for key, value in overlay.items():
            out[key] = merge(base[key], value) if key in base else value
        return out
    if isinstance(base, list) and isinstance(overlay, list):
        key = _identity(base + overlay)
        if key is None:
            return overlay
        merged = [dict(i) for i in base]
        index = {i[key]: n for n, i in enumerate(merged)}
        for item in overlay:
            if item[key] in index:
                merged[index[item[key]]] = merge(merged[index[item[key]]], item)
            else:
                index[item[key]] = len(merged)
                merged.append(item)
        return merged
    return overlay


def dumps(doc: Any) -> str:
    return json.dumps(doc, indent=2, ensure_ascii=False) + "\n"


def render(root: Path, overlay: str) -> str:
    base = json.loads((root / BASE).read_text())
    extra = json.loads((root / OVERLAYS / f"{overlay}.json").read_text())
    return dumps(merge(base, extra))


def render_local(root: Path = ROOT, check: bool = False) -> bool:
    """Write (or, with `check`, compare) the rig's realm. Returns whether the file on disk is now current."""
    text = render(root, "local")
    target = root / LOCAL_OUTPUT
    if check:
        return target.exists() and target.read_text() == text
    target.write_text(text)
    return True
