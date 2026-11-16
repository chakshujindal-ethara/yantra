"""Gate `restore-drill`: back the rig up, restore it, and prove it with the smoke test, timing both against the
plan's recovery targets (RPO 15 min, RTO 4 h). Destructive: everything written after the backup is gone, so it
runs only when asked with --yes. On the rig the recovery point is the age of the last backup; a deployed
environment meets the 15 minutes with managed Postgres point-in-time recovery (deployment/README.md)."""

import subprocess
import time
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from pathlib import Path

from yantra_cli.gates import GateResult

RPO_TARGET_S = 15 * 60
RTO_TARGET_S = 4 * 60 * 60

Runner = Callable[[Sequence[str]], subprocess.CompletedProcess[str]]


def run_script(argv: Sequence[str]) -> subprocess.CompletedProcess[str]:  # pragma: no cover - real processes
    return subprocess.run(list(argv), capture_output=True, text=True, check=False)


@dataclass
class RestoreDrill:
    repo: Path
    runner: Runner = run_script
    clock: Callable[[], float] = time.monotonic

    def run(self) -> GateResult:
        t0 = self.clock()
        backup = self.runner([str(self.repo / "deployment/scripts/backup.sh")])
        backup_s = self.clock() - t0
        if backup.returncode != 0:
            return GateResult("restore-drill", False, {"backup_exit": backup.returncode}, [_tail(backup.stderr)])
        directory = backup.stdout.strip().splitlines()[-1].strip()
        t1 = self.clock()
        restore = self.runner([str(self.repo / "deployment/scripts/restore.sh"), directory])
        rto = self.clock() - t1
        rpo = t1 - t0  # writes after the backup started are what a restore to it loses
        smoke_passed = "result" in restore.stdout and "PASS" in restore.stdout
        figures = {
            "backup_s": round(backup_s, 1),
            "recovery_point_age_s": round(rpo, 1),
            "rpo_target_s": RPO_TARGET_S,
            "restore_and_smoke_s": round(rto, 1),
            "rto_target_s": RTO_TARGET_S,
            "smoke_after_restore": "PASS" if smoke_passed else "FAIL",
            "backup": directory,
        }
        passed = restore.returncode == 0 and smoke_passed and rpo <= RPO_TARGET_S and rto <= RTO_TARGET_S
        notes = [] if restore.returncode == 0 else [_tail(restore.stderr or restore.stdout)]
        return GateResult("restore-drill", passed, figures, notes)


def _tail(text: str) -> str:
    lines = [ln for ln in text.strip().splitlines() if ln.strip()]
    return lines[-1] if lines else "no output"
