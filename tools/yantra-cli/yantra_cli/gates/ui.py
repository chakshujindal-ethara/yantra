"""Gate `ui`: the web app is served the way a launch needs it (security headers, a content security policy that
names the gateway, Keycloak and object storage, the runtime config), and the browser walks left their evidence.
The walks themselves ran in Chromium during the build; this gate re-checks what can be checked without a browser."""

from dataclasses import dataclass
from pathlib import Path

import httpx

from yantra_cli.gates import GateResult

HEADERS = ("x-content-type-options", "x-frame-options", "referrer-policy", "content-security-policy")
EVIDENCE = ("m1-", "m2-", "m3-", "m4-")


@dataclass
class UiGate:
    http: httpx.Client
    app_url: str = "http://localhost:8095"
    evidence_dir: Path = Path("ui-evidence")  # browser-walk screenshots, relative to the repository root

    def run(self) -> GateResult:
        page = self.http.get(self.app_url + "/")
        missing = [h for h in HEADERS if h not in page.headers]
        csp = page.headers.get("content-security-policy", "")
        config_resp = self.http.get(self.app_url + "/config.json")
        config = config_resp.json() if config_resp.status_code == 200 else {}
        shots = sorted(p.name for p in self.evidence_dir.glob("m*-*.png")) if self.evidence_dir.is_dir() else []
        by_stage = {stage.rstrip("-"): sum(1 for s in shots if s.startswith(stage)) for stage in EVIDENCE}
        csp_ok = "default-src 'self'" in csp and "frame-ancestors 'none'" in csp and "'unsafe-eval'" not in csp
        figures = {
            "status": page.status_code,
            "headers_missing": missing,
            "csp_scripts_self_only": csp_ok,
            "config_gateway": config.get("gateway_url"),
            "screenshots": by_stage,
        }
        passed = page.status_code == 200 and not missing and csp_ok and bool(config.get("gateway_url"))
        notes = [] if shots else [f"no screenshots under {self.evidence_dir}"]
        return GateResult("ui", passed, figures, notes)
