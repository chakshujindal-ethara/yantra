"""Every module's migrations to head, from inside the image (the compose `migrate` service and the Helm hook Jobs):
    python -m yantra_common.migrate                      # the default modules, in order
    python -m yantra_common.migrate market talent         # some of them
Each module owns its schema, so the order carries no dependency. `YANTRA_SERVICES_ROOT` (default `/app/services`)
is where the modules' `alembic.ini` files live; the database URL comes from `YANTRA_DATABASE_URL` as everywhere."""

import logging
import os
import sys
from collections.abc import Sequence
from pathlib import Path

from alembic import command
from alembic.config import Config

MODULES = ("market", "talent", "assess", "quality", "payout", "notify", "tracker", "analytics")
log = logging.getLogger("yantra.migrate")


def upgrade(modules: Sequence[str], root: Path, url: str | None = None) -> list[str]:
    """Upgrade each module to head; returns the modules migrated. An unknown module fails before any runs."""
    inis = [root / m / "alembic.ini" for m in modules]
    missing = [str(p) for p in inis if not p.is_file()]
    if missing:
        raise FileNotFoundError("no alembic.ini at " + ", ".join(missing))
    for module, ini in zip(modules, inis, strict=True):
        cfg = Config(str(ini))
        if url:
            cfg.attributes["url"] = url
        log.info("migrating module=%s", module)
        command.upgrade(cfg, "head")
    return list(modules)


def main(argv: Sequence[str]) -> int:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
    root = Path(os.environ.get("YANTRA_SERVICES_ROOT", "/app/services"))
    upgrade(list(argv) or list(MODULES), root)
    return 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main(sys.argv[1:]))
