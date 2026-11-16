"""The tracker's own settings (`YANTRA_TRACKER_*`), so the module reads them without the whole process
configuration."""

from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class TrackerSettings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="YANTRA_TRACKER_", extra="ignore")

    retention_days: int = 30  # samples and screenshot references are purged after this
    default_cap_hours: int = 40  # the weekly cap when neither the worker nor the project has one
    stale_minutes: int = 15  # an open session with no sample for this long is ended by the stale job
    skew_seconds: int = 300  # how far a sample's clock may sit from the server's


@lru_cache(maxsize=1)
def tracker_settings() -> TrackerSettings:
    return TrackerSettings()
