"""Pure rules of the market module: no session, no I/O. Tested without a database."""

import uuid
from decimal import ROUND_HALF_UP, Decimal
from typing import Any

from jsonschema import Draft202012Validator
from jsonschema.exceptions import SchemaError
from pydantic import BaseModel

from yantra_common.storage import looks_like_ref, parse_ref

MAX_DEPTH = 32
MAX_PATTERN = 200
MAX_JSON_BYTES = 256 * 1024  # a payload or an answer; keeps every event well under the bus's 1 MB message cap
MAX_SCHEMA_BYTES = 64 * 1024  # a project's JSON Schema: stored once, sent to the app with every batch it browses


def json_size(value: Any) -> int:
    import json

    return len(json.dumps(value, separators=(",", ":")).encode())


class LineError(BaseModel):
    line: int
    external_ref: str
    reason: str


class ImportReport(BaseModel):
    total: int
    accepted: int
    errors: list[LineError]


class ImportLine(BaseModel):
    """One accepted line, ready to become a unit."""

    external_ref: str
    payload: dict[str, Any]
    assigned_worker_id: uuid.UUID | None
    payload_uri: str | None = None  # the key of the unit's stored media, when its payload names one


def media_ref(payload: dict[str, Any], prefix: str, bucket: str | None) -> tuple[str | None, str | None]:
    """The key of the first stored-media ref among a payload's top-level strings, and the first problem with any
    ref: a value that looks like a ref must name an object under the project's own prefix."""
    found: str | None = None
    for name, value in payload.items():
        if not looks_like_ref(value):
            continue
        try:
            key = parse_ref(value, bucket)
        except ValueError as e:
            return None, f"payload: {name}: {e}"
        if not key.startswith(prefix):
            return None, f"payload: {name}: ref outside the project"
        found = found or key
    return found, None


def depth(value: object, level: int = 0) -> int:
    """Nesting depth of a JSON value. Guards every client-supplied document against recursion blow-ups."""
    if level > MAX_DEPTH:
        return level
    if isinstance(value, dict):
        return max((depth(v, level + 1) for v in value.values()), default=level + 1)
    if isinstance(value, list):
        return max((depth(v, level + 1) for v in value), default=level + 1)
    return level


def check_schema(schema: dict[str, Any]) -> str | None:
    """Why a client-supplied JSON Schema is refused, or None when it is safe to store and run.
    `$ref` is refused outright (no remote lookups, no recursion); regex patterns are capped in length."""
    if depth(schema) > MAX_DEPTH:
        return "schema nests deeper than 32 levels"
    problems = []

    def walk(node: object) -> None:
        if isinstance(node, dict):
            if "$ref" in node or "$dynamicRef" in node:
                problems.append("$ref is not allowed")
            patterns = {"pattern": [node["pattern"]] if "pattern" in node else []}
            patterns["patternProperties"] = list(node.get("patternProperties") or {})
            for key, found in patterns.items():
                if any(not isinstance(p, str) or len(p) > MAX_PATTERN for p in found):
                    problems.append(f"{key} longer than {MAX_PATTERN} characters")
            for v in node.values():
                walk(v)
        elif isinstance(node, list):
            for v in node:
                walk(v)

    walk(schema)
    if problems:
        return problems[0]
    try:
        Draft202012Validator.check_schema(schema)
    except SchemaError as e:
        return f"not a valid JSON Schema: {e.message}"[:200]
    return None


def validate_lines(
    schema: dict[str, Any],
    lines: list[dict[str, Any]],
    existing_refs: set[str],
    media_prefix: str = "",
    bucket: str | None = None,
) -> tuple[ImportReport, list[ImportLine]]:
    """Every line needs a unique `external_ref`, a `payload` object that satisfies the project's schema, and an
    optional `assigned_worker_id` UUID. A payload string that looks like stored media (`s3://...` or `projects/...`)
    must name an object under `media_prefix` in `bucket`. Line numbers are 1-based, as in the file the client sent."""
    validator = Draft202012Validator(schema)
    seen: set[str] = set(existing_refs)
    errors: list[LineError] = []
    accepted: list[ImportLine] = []
    for i, line in enumerate(lines, start=1):
        ref = str(line.get("external_ref") or "")
        if not ref or len(ref) > 200:
            errors.append(LineError(line=i, external_ref=ref[:200], reason="external_ref: missing or over 200 chars"))
            continue
        if ref in seen:
            errors.append(LineError(line=i, external_ref=ref, reason="duplicate external_ref"))
            continue
        seen.add(ref)
        payload = line.get("payload")
        if not isinstance(payload, dict):
            errors.append(LineError(line=i, external_ref=ref, reason="payload: must be an object"))
            continue
        if depth(payload) > MAX_DEPTH:
            errors.append(LineError(line=i, external_ref=ref, reason="payload: nests deeper than 32 levels"))
            continue
        if json_size(payload) > MAX_JSON_BYTES:
            errors.append(LineError(line=i, external_ref=ref, reason="payload: over 256 KB"))
            continue
        problems = sorted(validator.iter_errors(payload), key=lambda e: list(e.path))
        if problems:
            where = "/".join(str(p) for p in problems[0].path) or "payload"
            errors.append(LineError(line=i, external_ref=ref, reason=f"payload: {where}: {problems[0].message}"[:300]))
            continue
        uri, problem = media_ref(payload, media_prefix, bucket)
        if problem:
            errors.append(LineError(line=i, external_ref=ref, reason=problem[:300]))
            continue
        assigned = line.get("assigned_worker_id")
        try:
            assigned_id = uuid.UUID(str(assigned)) if assigned else None
        except ValueError:
            errors.append(LineError(line=i, external_ref=ref, reason="assigned_worker_id: not a UUID"))
            continue
        accepted.append(ImportLine(external_ref=ref, payload=payload, assigned_worker_id=assigned_id, payload_uri=uri))
    return ImportReport(total=len(lines), accepted=len(accepted), errors=errors), accepted


def check_answer(schema: dict[str, Any], answer: dict[str, Any]) -> str | None:
    """The first problem with an answer against the project's answer schema, as `path: message`, or None.
    Errors are ordered by path so the same bad answer always names the same problem."""
    problems = sorted(Draft202012Validator(schema).iter_errors(answer), key=lambda e: [str(p) for p in e.path])
    if not problems:
        return None
    where = "/".join(str(p) for p in problems[0].path)
    return (f"{where}: {problems[0].message}" if where else problems[0].message)[:300]


def margin(unit_price: Decimal, unit_pay: Decimal, review_pay: Decimal) -> Decimal:
    """Contribution margin per unit as a fraction of price. A zero price is a zero margin, never a division error."""
    if unit_price <= 0:
        return Decimal("0")
    return ((unit_price - unit_pay - review_pay) / unit_price).quantize(Decimal("0.0001"), rounding=ROUND_HALF_UP)
