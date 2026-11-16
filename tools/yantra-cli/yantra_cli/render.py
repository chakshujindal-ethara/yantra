"""Readable output for a terminal: a table for a list of records, key: value lines for one record, raw
text as is. `--json` prints the JSON instead."""

import json
from typing import Any


def _cell(v: Any) -> str:
    if v is None:
        return "-"
    if isinstance(v, dict | list):
        return json.dumps(v, separators=(",", ":"))[:60]
    return str(v)


def table(rows: list[dict[str, Any]]) -> str:
    if not rows:
        return "(none)"
    columns = list(dict.fromkeys(k for row in rows for k in row))
    cells = [[_cell(row.get(c)) for c in columns] for row in rows]
    widths = [max(len(c), *(len(r[i]) for r in cells)) for i, c in enumerate(columns)]
    line = "  ".join(c.ljust(widths[i]) for i, c in enumerate(columns))
    body = ["  ".join(r[i].ljust(widths[i]) for i in range(len(columns))) for r in cells]
    return "\n".join([line, *body])


def record(doc: dict[str, Any]) -> str:
    width = max((len(k) for k in doc), default=0)
    lines = []
    for k, v in doc.items():
        if isinstance(v, list) and v and all(isinstance(x, dict) for x in v):
            lines.append(f"{k}:")
            lines.append("  " + table(v).replace("\n", "\n  "))
        elif isinstance(v, dict | list):
            lines.append(f"{k.ljust(width)}  {json.dumps(v, indent=2).replace(chr(10), chr(10) + ' ' * (width + 2))}")
        else:
            lines.append(f"{k.ljust(width)}  {_cell(v)}")
    return "\n".join(lines)


def render(data: Any, as_json: bool = False) -> str:
    if as_json:
        return json.dumps(data, indent=2) if not isinstance(data, str) else data
    if isinstance(data, str):
        return data.rstrip("\n")
    if isinstance(data, list):
        return table(data) if all(isinstance(x, dict) for x in data) else "\n".join(_cell(x) for x in data)
    if isinstance(data, dict):
        return record(data)
    return _cell(data)
