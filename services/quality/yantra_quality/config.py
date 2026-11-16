"""Quality's own settings. `YANTRA_AUDIT_KEY` keys the HMAC that decides the 10% audit sample from a unit's id:
without the key nobody can tell which units an auditor will see, so a reviewer cannot learn to be careful only
there. The default is for the local rig only; a deployed environment (`YANTRA_ENV` not `local`) refuses it at
boot, naming the setting and never its value."""

from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict

from yantra_common.config import MIN_SECRET_LENGTH, Env

LOCAL_AUDIT_KEY = "local-dev-audit-key-change-me"


class QualitySettings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="YANTRA_", extra="ignore")

    env: Env = "local"
    audit_key: str = LOCAL_AUDIT_KEY


class AuditKeyRefused(RuntimeError):
    """A deployed environment configured with the rig's audit key, or one too short to be a secret."""


def refuse_rig_audit_key(s: QualitySettings) -> None:
    if s.env != "local" and (s.audit_key == LOCAL_AUDIT_KEY or len(s.audit_key) < MIN_SECRET_LENGTH):
        raise AuditKeyRefused(
            f"YANTRA_ENV={s.env} needs YANTRA_AUDIT_KEY set to a secret of at least {MIN_SECRET_LENGTH} characters"
        )


@lru_cache(maxsize=1)
def quality_settings() -> QualitySettings:
    s = QualitySettings()
    refuse_rig_audit_key(s)
    return s
