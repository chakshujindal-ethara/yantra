"""Picks the gates `yantra gate <name>` asked for, runs them in order and turns an abort into a FAIL row."""

import re
from argparse import Namespace
from collections.abc import Callable
from pathlib import Path

import httpx

from yantra_cli.client import GatewayError
from yantra_cli.config import Config
from yantra_cli.gates import GateAborted, GateResult
from yantra_cli.gates.delivery import DeliveryGate
from yantra_cli.gates.direct import Direct, DirectError
from yantra_cli.gates.money import MoneyParity
from yantra_cli.gates.restore import RestoreDrill
from yantra_cli.gates.security import SecurityGate
from yantra_cli.gates.storm import ClaimStorm
from yantra_cli.gates.ui import UiGate

NAMES = ("claim-storm", "money-parity", "delivery-gate", "security", "ui", "restore-drill")
REPO = Path(__file__).resolve().parents[4]


def rate_limit_from_compose(compose: Path, default: int = 600) -> int:
    """The gateway's per-caller limit as the rig sets it, so the burst exceeds exactly that."""
    try:
        text = compose.read_text()
    except OSError:
        return default
    found = re.search(r'YANTRA_GATEWAY_RATE_LIMIT_PER_MINUTE:\s*"?(\d+)', text)
    return int(found.group(1)) if found else default


def build(name: str, a: Namespace, cfg: Config, http: httpx.Client) -> Callable[[], GateResult]:
    api = Direct(http, a.work_url, a.money_url)
    if name == "claim-storm":
        return ClaimStorm(api, a.workers or 500, a.units or 2000, a.concurrency or 64).run
    if name == "money-parity":
        workers, units = (10, 100) if a.quick else (a.workers or 50, a.units or 1000)
        return MoneyParity(api, workers, units).run
    if name == "delivery-gate":
        return DeliveryGate(api, http).run
    if name == "security":
        limit = rate_limit_from_compose(REPO / "deployment/local/compose.yaml")
        return SecurityGate(cfg, a.password, http, limit).run
    if name == "ui":
        return UiGate(http, a.app_url).run
    return RestoreDrill(REPO).run


def selected(a: Namespace) -> list[str] | str:
    """The gate names to run, or the reason to refuse."""
    if a.name == "restore-drill" and not a.yes:
        return "restore-drill replaces the rig's data with a fresh backup of itself: add --yes"
    if a.name != "all":
        return [a.name]
    names = [n for n in NAMES if n != "restore-drill"]
    if a.with_restore:
        if not a.yes:
            return "--with-restore replaces the rig's data with a fresh backup of itself: add --yes"
        names.append("restore-drill")
    return names


def run(a: Namespace, cfg: Config, http: httpx.Client) -> list[GateResult]:
    names = selected(a)
    if isinstance(names, str):
        return [GateResult(a.name, False, {}, [names])]
    results = []
    for name in names:
        try:
            results.append(build(name, a, cfg, http)())
        except (GateAborted, DirectError, GatewayError, httpx.HTTPError) as e:
            results.append(GateResult(name, False, {}, [f"aborted: {e}"]))
    return results
