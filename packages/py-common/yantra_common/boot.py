"""What every process does first: logging in the configured format, then error reporting when it is configured."""

import logging

from yantra_common.http import configure_logging
from yantra_common.sentry import install_sentry


def boot(process: str, level: int = logging.INFO) -> None:
    configure_logging(level)
    install_sentry(process)
