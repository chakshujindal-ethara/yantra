"""`yantra gate <name>`: the Stage 1 launch gates as checks anyone can rerun on the rig. Each gate measures,
compares with the plan's target and returns a row: PASS or FAIL with the figures that decided it."""

from dataclasses import dataclass, field
from typing import Any


@dataclass
class GateResult:
    name: str
    passed: bool
    figures: dict[str, Any] = field(default_factory=dict)
    notes: list[str] = field(default_factory=list)

    def as_dict(self) -> dict[str, Any]:
        return {"gate": self.name, "result": "PASS" if self.passed else "FAIL", **self.figures, "notes": self.notes}


class GateAborted(Exception):
    """A gate could not run at all (the rig is missing a piece it needs): reported as FAIL with the reason."""


def table(results: list[GateResult]) -> str:
    """One line per gate: result, name, then the deciding figures as key=value."""
    lines = []
    for r in results:
        figures = "  ".join(f"{k}={v}" for k, v in r.figures.items())
        lines.append(f"{'PASS' if r.passed else 'FAIL'}  {r.name:<14} {figures}")
        lines.extend(f"      - {n}" for n in r.notes)
    return "\n".join(lines)
